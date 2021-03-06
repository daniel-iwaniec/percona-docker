#!/bin/bash

set -o errexit
set -o xtrace

GARBD_OPTS=""
SOCAT_OPTS="TCP-LISTEN:4444,reuseaddr,retry=30"

function get_backup_source() {
    peer-list -on-start=/usr/bin/get-pxc-state -service=$PXC_SERVICE 2>&1 \
        | grep wsrep_ready:ON:wsrep_connected:ON:wsrep_local_state_comment:Synced:wsrep_cluster_status:Primary \
        | sort \
        | tail -1 \
        | cut -d : -f 2 \
        | cut -d . -f 1
}

function check_ssl() {
    CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    if [ -f /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt ]; then
        CA=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
    fi
    SSL_DIR=${SSL_DIR:-/etc/mysql/ssl}
    if [ -f ${SSL_DIR}/ca.crt ]; then
        CA=${SSL_DIR}/ca.crt
    fi
    SSL_INTERNAL_DIR=${SSL_INTERNAL_DIR:-/etc/mysql/ssl-internal}
    if [ -f ${SSL_INTERNAL_DIR}/ca.crt ]; then
        CA=${SSL_INTERNAL_DIR}/ca.crt
    fi

    KEY=${SSL_DIR}/tls.key
    CERT=${SSL_DIR}/tls.crt
    if [ -f ${SSL_INTERNAL_DIR}/tls.key -a -f ${SSL_INTERNAL_DIR}/tls.crt ]; then
        KEY=${SSL_INTERNAL_DIR}/tls.key
        CERT=${SSL_INTERNAL_DIR}/tls.crt
    fi

    if [ -f "$CA" -a -f "$KEY" -a -f "$CERT" ]; then
        GARBD_OPTS="socket.ssl_ca=${CA};socket.ssl_cert=${CERT};socket.ssl_key=${KEY};socket.ssl_cipher=;${GARBD_OPTS}"
        SOCAT_OPTS="openssl-listen:4444,reuseaddr,cert=${CERT},key=${KEY},cafile=${CA},verify=1,retry=30"
    fi
}

function request_streaming() {
    local LOCAL_IP=$(hostname -i)
    local NODE_NAME=$(get_backup_source)

    if [ -z "$NODE_NAME" ]; then
        peer-list -on-start=/usr/bin/get-pxc-state -service=$PXC_SERVICE
        echo "[ERROR] Cannot find node for backup"
        exit 1
    fi

    timeout -k 25 20 \
        garbd \
            --address "gcomm://$NODE_NAME.$PXC_SERVICE?gmcast.listen_addr=tcp://0.0.0.0:4567" \
            --donor "$NODE_NAME" \
            --group "$PXC_SERVICE" \
            --options "$GARBD_OPTS" \
            --sst "xtrabackup-v2:$LOCAL_IP:4444/xtrabackup_sst//1" \
            2>&1 | tee /tmp/garbd.log

    if grep 'State transfer request failed' /tmp/garbd.log; then
        exit 1
    fi
    if grep 'WARN: Protocol violation. JOIN message sender ... (garb) is not in state transfer' /tmp/garbd.log; then
        exit 1
    fi
    if grep 'WARN: Rejecting JOIN message from ... (garb): new State Transfer required.' /tmp/garbd.log; then
        exit 1
    fi
    if grep 'INFO: Shifting CLOSED -> DESTROYED (TO: -1)' /tmp/garbd.log; then
        exit 1
    fi
}

function backup_volume() {
    BACKUP_DIR=${BACKUP_DIR:-/backup/$PXC_SERVICE-$(date +%F-%H-%M)}
    mkdir -p "$BACKUP_DIR"
    cd "$BACKUP_DIR" || exit

    echo "Backup to $BACKUP_DIR started"
    request_streaming

    # mostly always the first "socat" run receive SST info only
    socat -u "$SOCAT_OPTS" stdio \
        > xtrabackup.stream

    # but sometimes we receive real data during the first "socat" run
    # in such case we need to detect if we need to do the second "socat" run
    if (( $(stat -c%s xtrabackup.stream) < 50000000 )); then
        socat -u "$SOCAT_OPTS" stdio \
            > xtrabackup.stream
    fi
    echo "Backup finished"

    stat xtrabackup.stream
    if (( $(stat -c%s xtrabackup.stream) < 50000000 )); then
        echo empty backup
        exit 1
    fi
    md5sum xtrabackup.stream | tee md5sum.txt
}

function backup_s3() {
    S3_BUCKET_PATH=${S3_BUCKET_PATH:-$PXC_SERVICE-$(date +%F-%H-%M)-xtrabackup.stream}

    echo "Backup to s3://$S3_BUCKET/$S3_BUCKET_PATH started"
    { set +x; } 2> /dev/null
    echo "+ mc -C /tmp/mc config host add dest "${ENDPOINT:-https://s3.amazonaws.com}" ACCESS_KEY_ID SECRET_ACCESS_KEY"
    mc -C /tmp/mc config host add dest "${ENDPOINT:-https://s3.amazonaws.com}" "$ACCESS_KEY_ID" "$SECRET_ACCESS_KEY"
    set -x
    xbcloud delete --storage=s3 --s3-bucket="$S3_BUCKET" "$S3_BUCKET_PATH" || :
    request_streaming

    # mostly always the first "socat" run receive SST info only
    socat -u "$SOCAT_OPTS" stdio \
        | xbcloud put --storage=s3 --parallel=10 --md5 --s3-bucket="$S3_BUCKET" "$S3_BUCKET_PATH"

    # but sometimes we receive real data during the first "socat" run
    # in such case we need to detect if we need to do the second "socat" run
    ib_size=$(mc -C /tmp/mc stat --json "dest/$S3_BUCKET/$S3_BUCKET_PATH/xtrabackup_checkpoints.00000000000000000000" | sed -e 's/.*"size":\([0-9]*\).*/\1/')
    if [[ $ib_size =~ "Object does not exist" ]] || (( $ib_size < 20 )); then
        xbcloud delete --storage=s3 --s3-bucket="$S3_BUCKET" "$S3_BUCKET_PATH"
        socat -u "$SOCAT_OPTS" stdio \
            | xbcloud put --storage=s3 --parallel=10 --md5 --s3-bucket="$S3_BUCKET" "$S3_BUCKET_PATH"
    fi
    echo "Backup finished"

    mc -C /tmp/mc stat "dest/$S3_BUCKET/$S3_BUCKET_PATH.md5"
    md5_size=$(mc -C /tmp/mc stat --json "dest/$S3_BUCKET/$S3_BUCKET_PATH.md5" | sed -e 's/.*"size":\([0-9]*\).*/\1/')
    if [[ $md5_size =~ "Object does not exist" ]] || (( $md5_size < 25000 )); then
        echo empty backup
        exit 1
    fi
}

check_ssl
if [ -n "$S3_BUCKET" ]; then
    backup_s3
else
    backup_volume
fi

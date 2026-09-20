#!/bin/bash
# Shared MTProxy launcher — reads secrets from pool file
# Usage: mtproxy-shared-{mode}.sh
# Pool file: /etc/mtproxy/mtproxy-shared-{mode}.secrets (one hex secret per line)

MODE="${1:-https}"

case "$MODE" in
    https)           HTTP_PORT=2501; TCP_PORT=3501 ;;
    https-lanes)     HTTP_PORT=2502; TCP_PORT=3502 ;;
    websocket)       HTTP_PORT=2503; TCP_PORT=3503 ;;
    websocket-lanes) HTTP_PORT=2504; TCP_PORT=3504 ;;
    *) echo "Unknown mode: $MODE"; exit 1 ;;
esac

SECRETS_FILE="/etc/mtproxy/mtproxy-shared-${MODE}.secrets"
WORKERS=1
MAX_CONN=4096

if [ ! -f "$SECRETS_FILE" ]; then
    echo "Secrets file not found: $SECRETS_FILE"
    exit 1
fi

# Build -S flags from pool file
SECRET_ARGS=""
while IFS= read -r line; do
    line=$(echo "$line" | tr -d '[:space:]')
    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue
    SECRET_ARGS="$SECRET_ARGS -S $line"
done < "$SECRETS_FILE"

if [ -z "$SECRET_ARGS" ]; then
    echo "No secrets in $SECRETS_FILE"
    exit 1
fi

exec /opt/MTProxy/objs/bin/mtproto-proxy \
    -u mtproxy \
    -p $TCP_PORT \
    -H $HTTP_PORT \
    $SECRET_ARGS \
    --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf \
    -M $WORKERS \
    -C $MAX_CONN

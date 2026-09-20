#!/bin/bash
# Manage shared MTProxy secrets pool
# Usage: mtproxy-pool.sh {add|remove|restart} <mode> [secret]
#   add <mode> <secret>     — add secret to pool, restart shared MTProxy
#   remove <mode> <secret>  — remove secret from pool, restart shared MTProxy
#   restart <mode>          — just restart shared MTProxy (after manual pool edit)

ACTION="${1}"
MODE="${2}"
SECRET="${3}"

SECRETS_FILE="/etc/mtproxy/mtproxy-shared-${MODE}.secrets"
SERVICE_NAME="mtproxy-shared-${MODE}"

if [ -z "$ACTION" ] || [ -z "$MODE" ]; then
    echo "Usage: $0 {add|remove|restart} <mode> [secret]"
    exit 1
fi

# Ensure secrets file exists
touch "$SECRETS_FILE"

case "$ACTION" in
    add)
        if [ -z "$SECRET" ]; then
            echo "Secret required for add"
            exit 1
        fi
        # Check if already exists
        if grep -qFx "$SECRET" "$SECRETS_FILE"; then
            echo "Secret already in pool for $MODE"
            exit 0
        fi
        echo "$SECRET" >> "$SECRETS_FILE"
        echo "Added secret to $MODE pool"
        ;;
    remove)
        if [ -z "$SECRET" ]; then
            echo "Secret required for remove"
            exit 1
        fi
        # Remove exact match
        grep -vFx "$SECRET" "$SECRETS_FILE" > "${SECRETS_FILE}.tmp"
        mv "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
        echo "Removed secret from $MODE pool"
        ;;
    restart)
        echo "Restarting $SERVICE_NAME..."
        ;;
    *)
        echo "Unknown action: $ACTION"
        exit 1
        ;;
esac

# Restart the shared MTProxy service
systemctl restart "$SERVICE_NAME"
sleep 1
if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "$SERVICE_NAME is active"
    echo "Pool contents ($(wc -l < "$SECRETS_FILE") secrets):"
    cat "$SECRETS_FILE"
else
    echo "ERROR: $SERVICE_NAME failed to start!"
    journalctl -u "$SERVICE_NAME" --no-pager -n 5
    exit 1
fi

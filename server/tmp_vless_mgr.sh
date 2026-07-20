#!/bin/bash
# VLESS+XHTTP+REALITY user management
# Usage: vless_mgr.sh add <username>
#        vless_mgr.sh del <username>
#        vless_mgr.sh list
#        vless_mgr.sh gen-config <username>

XRAY_CONFIG="/usr/local/etc/xray/config.json"
USERS_FILE="/etc/xray/users.json"
OUT_DIR="/root/proxy_users/vless"
PUBLIC_KEY="iqmUrTnhYDcm-hhuGJaze6dTGNIcvyMOyYIN7LB4kU4"
SHORT_ID="2e30b986cabb4bca"
HOST="76t05pyu.ikill.baby"
PORT="443"

mkdir -p "$OUT_DIR" "$(dirname "$USERS_FILE")"
touch "$USERS_FILE"

# Initialize users file if empty
if [ ! -s "$USERS_FILE" ]; then
    echo "{}" > "$USERS_FILE"
fi

gen_uuid() {
    xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

make_link() {
    local uuid="$1" user="$2"
    echo "vless://${uuid}@${HOST}:${PORT}?security=reality&type=xhttp&path=%2Fvless&sni=&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2Fdns-query%2F#${user}"
}

add_user() {
    local user="$1"
    local uuid
    uuid=$(gen_uuid)
    
    # Add to users file
    local tmp
    tmp=$(mktemp)
    python3 -c "
import json
with open('$USERS_FILE') as f:
    u = json.load(f)
u['$user'] = '$uuid'
with open('$tmp', 'w') as f:
    json.dump(u, f, indent=2)
" && mv "$tmp" "$USERS_FILE"
    
    # Generate configs
    local link
    link=$(make_link "$uuid" "$user")
    echo "$link" > "$OUT_DIR/${user}.uri"
    echo "$link" | qrencode -t UTF8 2>/dev/null > "$OUT_DIR/${user}.qr" || true
    
    # Update xray config
    update_xray_config
    
    echo "User $user added (UUID: $uuid)"
    echo "Link: $link"
}

del_user() {
    local user="$1"
    local tmp
    tmp=$(mktemp)
    python3 -c "
import json
with open('$USERS_FILE') as f:
    u = json.load(f)
u.pop('$user', None)
with open('$tmp', 'w') as f:
    json.dump(u, f, indent=2)
" && mv "$tmp" "$USERS_FILE"
    
    rm -f "$OUT_DIR/${user}".*
    update_xray_config
    echo "User $user removed"
}

list_users() {
    echo "VLESS+XHTTP+REALITY users:"
    python3 -c "
import json
with open('$USERS_FILE') as f:
    u = json.load(f)
for name, uuid in u.items():
    print(f'  {name}: {uuid}')
" 2>/dev/null || echo "  (no users)"
}

update_xray_config() {
    local tmp
    tmp=$(mktemp)
    python3 -c "
import json

with open('$USERS_FILE') as f:
    users = json.load(f)

with open('$XRAY_CONFIG') as f:
    cfg = json.load(f)

clients = [{'id': uid, 'flow': ''} for uid in users.values()]
cfg['inbounds'][0]['settings']['clients'] = clients

with open('$tmp', 'w') as f:
    json.dump(cfg, f, indent=2)
" && mv "$tmp" "$XRAY_CONFIG"
    
    systemctl restart xray
    echo "xray restarted with updated config"
}

case "${1:-list}" in
    add)
        if [ -z "$2" ]; then
            echo "Usage: $0 add <username>"
            exit 1
        fi
        add_user "$2"
        ;;
    del)
        if [ -z "$2" ]; then
            echo "Usage: $0 del <username>"
            exit 1
        fi
        del_user "$2"
        ;;
    list)
        list_users
        ;;
    gen-config)
        if [ -z "$2" ]; then
            echo "Usage: $0 gen-config <username>"
            exit 1
        fi
        local uuid
        uuid=$(python3 -c "
import json
with open('$USERS_FILE') as f:
    u = json.load(f)
print(u.get('$2', ''))
" 2>/dev/null)
        if [ -z "$uuid" ]; then
            echo "User $2 not found"
            exit 1
        fi
        make_link "$uuid" "$2"
        ;;
    *)
        echo "Usage: $0 {add|del|list|gen-config} [username]"
        ;;
esac

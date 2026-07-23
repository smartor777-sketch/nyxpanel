#!/bin/bash
# Dev-adapted proxy_manager.sh for dev server (nyx.kuban-forum.ru / 2.26.51.8)

BASE_DIR="/root/proxy_users"
REGISTRY_FILE="$BASE_DIR/.registry"

HY2_CONFIG="/etc/hysteria/config.yaml"
AWG_CONFIG="/etc/amnezia/amneziawg/awg0.conf" 
NAIVE_CONFIG="/etc/caddy/Caddyfile"  
AWG_INTERFACE="awg0"

SERVER_DOMAIN="nyx.kuban-forum.ru"
AWG_SUBNET="10.9.9"
NAIVE_PORT="8443" 
MIERU_IP="2.26.51.8"
MIERU_PORTS="444-448"
MIERU_CONFIG="/etc/mita/server.json"

OLRTC_USERS_FILE="/etc/olcrtc/users.json"
OLRTC_CONFIG="/root/.config/olcrtc/server.yaml"
OLRTC_SERVICE="olcrtc"
OLRTC_ICE="ws://nyx.kuban-forum.ru:30001/ice"
OLRTC_ROOM_URL="https://meet.egovm.ru/pxy-oootubww.ikill.baby"
OLRTC_CRYPTO_KEY="2967bab5e92bb2c9ceef2e0e9b7b65d1dabca7d7b2db8c005250a591d2ce4b31"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
VLESS_USERS_FILE="/etc/xray/users.json"
XRAY_SERVICE="xray"
VLESS_HOST="nyx.kuban-forum.ru"
VLESS_PORT="443"
VLESS_SNI="1.1.1.1"
VLESS_PUBLIC_KEY="D1P25Vpg6ATLGHswPBJEelp4bO3bb0W2nkchNDiU9V4="
VLESS_SHORT_ID="e508aadcfd50611a"

GREEN='\033[1;92m'
RED='\033[1;91m'
YELLOW='\033[1;93m'
WHITE='\033[1;97m'
CYAN='\033[1;96m'
NC='\033[0m'

init() {
    mkdir -p "$BASE_DIR"
    touch "$REGISTRY_FILE"
    if ! command -v jq &> /dev/null; then echo -e "${RED}jq not found${NC}"; exit 1; fi
    if ! command -v yq &> /dev/null; then echo -e "${RED}yq not found${NC}"; exit 1; fi
    if ! command -v qrencode &> /dev/null; then echo -e "${RED}qrencode not found${NC}"; exit 1; fi
}

check_user_exists() {
    if [ ! -d "$BASE_DIR/$1" ]; then
        echo -e "${RED}User '$1' not found${NC}"; return 1
    fi; return 0
}

generate_qr() {
    local content=$1; local output_path=$2
    echo "$content" | qrencode -t PNG -o "$output_path"
    echo -e "${GREEN}QR saved: $output_path${NC}"
}

init_mieru_config() {
    if [ ! -f "$MIERU_CONFIG" ]; then
        if [ -f "/tmp/mita.json" ]; then
            cp "/tmp/mita.json" "$MIERU_CONFIG"
        else
            jq -n --arg ports "$MIERU_PORTS" \
              '{"portBindings": [{"portRange": $ports, "protocol": "TCP"}], "users": [], "loggingLevel": "INFO", "mtu": 1400}' > "$MIERU_CONFIG"
        fi
    fi
}

apply_mieru_config() {
    if [ -f "$MIERU_CONFIG" ]; then
        if mita apply config "$MIERU_CONFIG"; then
            mita stop 2>/dev/null || true; mita start
        else return 1; fi
    fi
}

add_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Username: " username; fi
    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Invalid chars${NC}"; return 1
    fi
    if [ -d "$BASE_DIR/$username" ]; then
        echo -e "${YELLOW}User '$username' exists${NC}"; return 1
    fi
    mkdir -p "$BASE_DIR/$username"
    echo "$username" >> "$REGISTRY_FILE"
    echo -e "${GREEN}User '$username' created${NC}"
}

del_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Username to delete: " username; fi
    username=$(echo "$username" | xargs)
    if [ -z "$username" ]; then echo -e "${RED}Empty username${NC}"; return 1; fi
    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then echo -e "${RED}Invalid chars${NC}"; return 1; fi
    if ! check_user_exists "$username"; then return 1; fi
    local target_dir="$BASE_DIR/$username"
    if [[ "$target_dir" != "$BASE_DIR/"* ]]; then echo -e "${RED}Path error${NC}"; return 1; fi
    if [ -f "$REGISTRY_FILE" ]; then
        grep -v -x -F "$username" "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp" && mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"
    fi
    if [ -f "$target_dir/.awg_pubkey" ] && [ -f "$AWG_CONFIG" ]; then
        awk -v user="$username" '$0 ~ "^# Peer: " user { skip=1; next } skip && /^\[Peer\]/ { skip=0 } !skip { print }' "$AWG_CONFIG" > /tmp/awg_tmp.conf && mv /tmp/awg_tmp.conf "$AWG_CONFIG"
        awg-quick down "$AWG_INTERFACE" 2>/dev/null || true
        awg-quick up "$AWG_INTERFACE" 2>/dev/null || true
    fi
    if [ -f "$NAIVE_CONFIG" ]; then
        sed -i "/basic_auth ${username} /d" "$NAIVE_CONFIG"
        systemctl reload caddy
    fi
    if [ -f "$target_dir/${username}_mieru.json" ] && [ -f "$MIERU_CONFIG" ]; then
        init_mieru_config
        jq --arg name "$username" 'del(.users[] | select(.name == $name))' "$MIERU_CONFIG" > "${MIERU_CONFIG}.tmp" && mv "${MIERU_CONFIG}.tmp" "$MIERU_CONFIG"
        apply_mieru_config
    fi
    if [ -f "$target_dir/${username}_hy2.json" ] && [ -f "$HY2_CONFIG" ]; then
        jq --arg user "$username" 'del(.auth.userpass[$user])' "$HY2_CONFIG" > /tmp/hy2_config.tmp && mv /tmp/hy2_config.tmp "$HY2_CONFIG"
        systemctl restart hysteria-server
    fi
    if { [ -f "$target_dir/${username}_olcrtc.json" ] || [ -f "$target_dir/${username}_olcrtc.yaml" ]; } && [ -f "$OLRTC_USERS_FILE" ]; then
        jq --arg user "$username" 'del(.[$user])' "$OLRTC_USERS_FILE" > /tmp/olcrtc_users.tmp && mv /tmp/olcrtc_users.tmp "$OLRTC_USERS_FILE"
    fi
    if [ -f "$target_dir/${username}_vless.uri" ] && [ -f "$VLESS_USERS_FILE" ]; then
        jq --arg user "$username" 'del(.[$user])' "$VLESS_USERS_FILE" > /tmp/vless_users.tmp && mv /tmp/vless_users.tmp "$VLESS_USERS_FILE"
        update_xray_config
    fi
    rm -rf "$target_dir"
    echo -e "${GREEN}User '$username' fully deleted${NC}"
}

remove_protocol() {
    local username=$1
    local protocol=$2
    if [ -z "$username" ] || [ -z "$protocol" ]; then
        echo -e "${RED}Usage: remove_protocol <username> <protocol>${NC}"
        echo -e "${YELLOW}Protocols: hy2, awg, naive, mieru, olcrtc, vless${NC}"
        return 1
    fi
    if ! check_user_exists "$username"; then return 1; fi
    local user_dir="$BASE_DIR/$username"
    case "$protocol" in
        hy2)
            if [ -f "$user_dir/${username}_hy2.json" ] && [ -f "$HY2_CONFIG" ]; then
                jq --arg user "$username" 'del(.auth.userpass[$user])' "$HY2_CONFIG" > /tmp/hy2_config.tmp && mv /tmp/hy2_config.tmp "$HY2_CONFIG"
                systemctl restart hysteria-server
                rm -f "$user_dir/${username}_hy2.json" "$user_dir/${username}_hy2.png"
                echo -e "${GREEN}Hy2 removed for $username${NC}"
            else
                echo -e "${YELLOW}Hy2 not found for $username${NC}"
            fi ;;
        awg)
            if [ -f "$user_dir/${username}_awg.conf" ] && [ -f "$AWG_CONFIG" ]; then
                awk -v user="$username" '$0 ~ "^# Peer: " user { skip=1; next } skip && /^\[Peer\]/ { skip=0 } !skip { print }' "$AWG_CONFIG" > /tmp/awg_tmp.conf && mv /tmp/awg_tmp.conf "$AWG_CONFIG"
                awg-quick down "$AWG_INTERFACE" 2>/dev/null || true
                awg-quick up "$AWG_INTERFACE" 2>/dev/null || true
                rm -f "$user_dir/${username}_awg.conf" "$user_dir/${username}_awg.png" "$user_dir/.awg_pubkey"
                echo -e "${GREEN}AWG removed for $username${NC}"
            else
                echo -e "${YELLOW}AWG not found for $username${NC}"
            fi ;;
        naive)
            if [ -f "$user_dir/${username}_naive.json" ] && [ -f "$NAIVE_CONFIG" ]; then
                sed -i "/basic_auth ${username} /d" "$NAIVE_CONFIG"
                systemctl reload caddy
                rm -f "$user_dir/${username}_naive.json" "$user_dir/${username}_naive.png"
                echo -e "${GREEN}NaiveProxy removed for $username${NC}"
            else
                echo -e "${YELLOW}NaiveProxy not found for $username${NC}"
            fi ;;
        mieru)
            if [ -f "$user_dir/${username}_mieru.json" ] && [ -f "$MIERU_CONFIG" ]; then
                init_mieru_config
                jq --arg name "$username" 'del(.users[] | select(.name == $name))' "$MIERU_CONFIG" > "${MIERU_CONFIG}.tmp" && mv "${MIERU_CONFIG}.tmp" "$MIERU_CONFIG"
                apply_mieru_config
                rm -f "$user_dir/${username}_mieru.json" "$user_dir/${username}_mieru.png" "$user_dir/${username}_mieru_standalone.json" "$user_dir/${username}_nekobox.txt"
                echo -e "${GREEN}Mieru removed for $username${NC}"
            else
                echo -e "${YELLOW}Mieru not found for $username${NC}"
            fi ;;
        olcrtc)
            if { [ -f "$user_dir/${username}_olcrtc.json" ] || [ -f "$user_dir/${username}_olcrtc.yaml" ]; } && [ -f "$OLRTC_USERS_FILE" ]; then
                jq --arg user "$username" 'del(.[$user])' "$OLRTC_USERS_FILE" > /tmp/olcrtc_users.tmp && mv /tmp/olcrtc_users.tmp "$OLRTC_USERS_FILE"
                systemctl restart "$OLRTC_SERVICE" 2>/dev/null || true
                rm -f $user_dir/${username}_olcrtc.json $user_dir/${username}_olcrtc.yaml $user_dir/${username}_olcrtc.uri $user_dir/${username}_olcrtc.txt $user_dir/${username}_olcrtc.png
                echo -e "${GREEN}olcRTC removed for $username${NC}"
            else
                echo -e "${YELLOW}olcRTC not found for $username${NC}"
            fi ;;
        vless)
            if [ -f "$user_dir/${username}_vless.uri" ] && [ -f "$VLESS_USERS_FILE" ]; then
                jq --arg user "$username" 'del(.[$user])' "$VLESS_USERS_FILE" > /tmp/vless_users.tmp && mv /tmp/vless_users.tmp "$VLESS_USERS_FILE"
                update_xray_config
                rm -f "$user_dir/${username}_vless.uri" "$user_dir/${username}_vless.png"
                echo -e "${GREEN}VLESS removed for $username${NC}"
            else
                echo -e "${YELLOW}VLESS not found for $username${NC}"
            fi ;;
        *)
            echo -e "${RED}Unknown protocol: $protocol${NC}"
            echo -e "${YELLOW}Valid: hy2, awg, naive, mieru, olcrtc, vless${NC}"
            return 1 ;;
    esac
}

list_users() {
    if [ ! -f "$REGISTRY_FILE" ] || [ ! -s "$REGISTRY_FILE" ]; then echo "Empty"; return; fi
    while IFS= read -r user || [ -n "$user" ]; do
        [ -z "$user" ] && continue
        echo -e "${GREEN}$user${NC}"
        [ -f "$BASE_DIR/$user/${user}_hy2.json" ] && echo "   - Hysteria 2"
        [ -f "$BASE_DIR/$user/${user}_awg.conf" ] && echo "   - AmneziaWG"
        [ -f "$BASE_DIR/$user/${user}_naive.json" ] && echo "   - NaiveProxy"
        [ -f "$BASE_DIR/$user/${user}_mieru.json" ] && echo "   - Mieru"
        [ -f "$BASE_DIR/$user/${user}_olcrtc.json" ] && echo "   - olcRTC"
        [ -f "$BASE_DIR/$user/${user}_vless.uri" ] && echo "   - VLESS+XHTTP+REALITY"
    done < "$REGISTRY_FILE"
}

update_xray_config() {
    if [ ! -f "$XRAY_CONFIG" ] || [ ! -f "$VLESS_USERS_FILE" ]; then return 1; fi
    python3 -c "
import json
with open('$VLESS_USERS_FILE') as f: users = json.load(f)
with open('$XRAY_CONFIG') as f: cfg = json.load(f)
clients = [{'id': uid, 'flow': '', 'email': name} for name, uid in users.items()]
if clients: cfg['inbounds'][0]['settings']['clients'] = clients
with open('$XRAY_CONFIG', 'w') as f: json.dump(cfg, f, indent=2)
" 2>/dev/null && systemctl restart $XRAY_SERVICE
}

add_hy2_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Username: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_hy2.json" ]; then echo -e "${YELLOW}Hy2 exists${NC}"; return 1; fi
    local password=$(openssl rand -hex 12)
    local server_port=$(yq '.listen' "$HY2_CONFIG" | tr -d ':"' | grep -oE '[0-9]+')
    [ -z "$server_port" ] && server_port=30000
    local obfs_type=$(yq '.obfs.type' "$HY2_CONFIG" | tr -d '"')
    local obfs_pass=""
    if [ "$obfs_type" = "salamander" ]; then
        obfs_pass=$(yq '.obfs.salamander.password // .obfs.password' "$HY2_CONFIG" | tr -d '"')
    fi
    jq --arg user "$username" --arg pass "$password" '.auth.userpass[$user] = $pass' "$HY2_CONFIG" > /tmp/hy2_config.tmp && mv /tmp/hy2_config.tmp "$HY2_CONFIG"
    systemctl restart hysteria-server
    local user_dir="$BASE_DIR/$username"
    local tag_name="pxy-hy2 - $username"
    local auth_str="${username}:${password}"
    jq -n --arg tag "$tag_name" --arg srv "$SERVER_DOMAIN" --argjson port "$server_port" --arg pass "$auth_str" --arg obfs_type "$obfs_type" --arg obfs_pass "$obfs_pass" \
      '{"outbounds": [{"type": "hysteria2", "tag": $tag, "server": $srv, "server_port": $port} + (if $obfs_type != "" and $obfs_type != "null" and $obfs_pass != "" and $obfs_pass != "null" then {obfs: {type: $obfs_type, password: $obfs_pass}} else {} end) + {"password": $pass, "tls": {"enabled": true, "server_name": $srv}}]}' \
      > "$user_dir/${username}_hy2_temp.json"
    jq . "$user_dir/${username}_hy2_temp.json" > "$user_dir/${username}_hy2.json"
    generate_qr "$(jq -c . "$user_dir/${username}_hy2_temp.json")" "$user_dir/${username}_hy2.png"
    rm "$user_dir/${username}_hy2_temp.json"
    echo -e "${GREEN}Hy2 added for $username${NC}"
}

add_awg_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Username: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_awg.conf" ]; then echo -e "${YELLOW}AWG exists${NC}"; return 1; fi
    if [ ! -f "$AWG_CONFIG" ]; then echo -e "${RED}AWG config not found${NC}"; return 1; fi
    local client_priv=$(awg genkey)
    local client_pub=$(echo "$client_priv" | awg pubkey)
    local psk=$(awg genpsk)
    local ip_num=2
    while grep -qE "^\s*AllowedIPs\s*=\s*${AWG_SUBNET}\.${ip_num}/32" "$AWG_CONFIG"; do
        ((ip_num++)); if [ $ip_num -gt 254 ]; then echo -e "${RED}No more IPs${NC}"; return 1; fi
    done
    local client_ip="${AWG_SUBNET}.${ip_num}/32"
    local server_priv=$(grep -E "^\s*PrivateKey" "$AWG_CONFIG" | head -1 | awk '{print $3}')
    local server_pub=$(echo "$server_priv" | awg pubkey)
    local server_port=$(grep -E "^\s*ListenPort" "$AWG_CONFIG" | awk '{print $3}')
    local awg_params=$(grep -E "^\s*(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1)" "$AWG_CONFIG" | sed 's/^\s*//')
    cat <<EOF >> "$AWG_CONFIG"
# Peer: $username
[Peer]
PublicKey = $client_pub
PresharedKey = $psk
AllowedIPs = $client_ip
EOF
    awg-quick down "$AWG_INTERFACE" 2>/dev/null || true
    awg-quick up "$AWG_INTERFACE" 2>/dev/null || true
    echo "$client_pub" > "$BASE_DIR/$username/.awg_pubkey"
    local client_conf="[Interface]
PrivateKey = $client_priv
Address = $client_ip
DNS = 77.88.8.8, 77.88.8.1
$awg_params

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = ${SERVER_DOMAIN}:${server_port}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25"
    echo "$client_conf" > "$BASE_DIR/$username/${username}_awg.conf"
    generate_qr "$client_conf" "$BASE_DIR/$username/${username}_awg.png"
    echo -e "${GREEN}AWG added for $username, IP: $client_ip${NC}"
}

add_naive_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Username: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_naive.json" ]; then echo -e "${YELLOW}Naive exists${NC}"; return 1; fi
    if [ ! -f "$NAIVE_CONFIG" ]; then echo -e "${RED}Caddy config not found${NC}"; return 1; fi
    local password=$(openssl rand -hex 12)
    local tag_name="pxy-naive - $username"
    sed -i "/forward_proxy {/a\\   basic_auth $username $password" "$NAIVE_CONFIG"
    systemctl reload caddy
    jq -n --arg tag "$tag_name" --arg srv "$SERVER_DOMAIN" --argjson port "$NAIVE_PORT" --arg user "$username" --arg pass "$password" \
      '{"outbounds": [{"type": "naive", "tag": $tag, "server": $srv, "server_port": $port, "username": $user, "password": $pass, "udp_over_tcp": true, "tls": {"enabled": true}}]}' \
      > "$BASE_DIR/$username/${username}_naive_temp.json"
    jq . "$BASE_DIR/$username/${username}_naive_temp.json" > "$BASE_DIR/$username/${username}_naive.json"
    generate_qr "$(jq -c . "$BASE_DIR/$username/${username}_naive_temp.json")" "$BASE_DIR/$username/${username}_naive.png"
    rm "$BASE_DIR/$username/${username}_naive_temp.json"
    echo -e "${GREEN}Naive added for $username${NC}"
}

add_mieru_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Username: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_mieru.json" ]; then echo -e "${YELLOW}Mieru exists${NC}"; return 1; fi
    local password=$(openssl rand -hex 8)
    init_mieru_config
    jq --arg name "$username" --arg pass "$password" '.users += [{"name": $name, "password": $pass}]' "$MIERU_CONFIG" > "${MIERU_CONFIG}.tmp" && mv "${MIERU_CONFIG}.tmp" "$MIERU_CONFIG"
    apply_mieru_config
    jq -n --arg tag "pxy-mieru - $username" --arg srv "$SERVER_DOMAIN" --argjson port 444 --arg user "$username" --arg pass "$password" \
      '{"outbounds": [{"type": "mieru", "tag": $tag, "server": $srv, "server_port": $port, "transport": "TCP", "username": $user, "password": $pass}]}' \
      > "$BASE_DIR/$username/${username}_mieru.json"
    jq -n --arg sip "$MIERU_IP" --arg sdom "$SERVER_DOMAIN" --arg pr "$MIERU_PORTS" --arg user "$username" --arg pass "$password" --arg tag "pxy-mieru - $username" \
      '{"activeProfile": "default", "socks5Port": 1080, "loggingLevel": "INFO", "profiles": [{"profileName": $tag, "user": {"name": $user, "password": $pass}, "servers": [{"ipAddress": $sip, "domainName": $sdom, "portBindings": [{"portRange": $pr, "protocol": "TCP"}]}]}]}' \
      > "$BASE_DIR/$username/${username}_mieru_standalone.json"
    cat > "$BASE_DIR/$username/${username}_nekobox.txt" << EOF
=== NekoBox Mieru ===
Server: $SERVER_DOMAIN
Port: 444
Protocol: TCP
Username: $username
Password: $password
EOF
    generate_qr "$(jq -c . "$BASE_DIR/$username/${username}_mieru.json")" "$BASE_DIR/$username/${username}_mieru.png"
    echo -e "${GREEN}Mieru added for $username${NC}"
}

add_olcrtc_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Username: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_olcrtc.json" ]; then echo -e "${YELLOW}olcRTC exists${NC}"; return 1; fi
    local password=$(openssl rand -hex 12)
    mkdir -p "$(dirname "$OLRTC_USERS_FILE")"
    python3 -c "import json; f='$OLRTC_USERS_FILE'; open(f,'a').close(); json.load(open(f))" 2>/dev/null || echo '{}' > "$OLRTC_USERS_FILE"
    jq --arg user "$username" --arg pass "$password" '.[$user] = $pass' "$OLRTC_USERS_FILE" > /tmp/olcrtc_users.tmp && mv /tmp/olcrtc_users.tmp "$OLRTC_USERS_FILE"
    cat > "$BASE_DIR/$username/${username}_olcrtc.json" << OLRTC_EOF
{
  "storage_id": "olcboxme-main",
  "name": "NYX Main",
  "endpoint": {
    "room_id": "${OLRTC_ROOM_URL}",
    "key": "${OLRTC_CRYPTO_KEY}"
  },
  "auth_provider": "jitsi",
  "transport": {
    "type": "datachannel"
  },
  "claims_user": "${username}",
  "claims_pass": "${password}"
}
OLRTC_EOF
    local olcrtc_uri="olcrtc://jitsi?datachannel&user=${username}&pass=${password}@${OLRTC_ROOM_URL}#${OLRTC_CRYPTO_KEY}\$pxy-olcrtc - ${username}"
    echo "$olcrtc_uri" > "$BASE_DIR/$username/${username}_olcrtc.uri"
    cat > "$BASE_DIR/$username/${username}_olcrtc.txt" << OLRTC_TXT
=== olcRTC ===
ICE: ws://${SERVER_DOMAIN}:30001
Room: $OLRTC_ROOM_URL
Key: $OLRTC_CRYPTO_KEY
User: $username
Pass: $password
SOCKS5: 127.0.0.1:1082
URI: $olcrtc_uri
OLRTC_TXT
    generate_qr "$olcrtc_uri" "$BASE_DIR/$username/${username}_olcrtc.png"
    echo -e "${GREEN}olcRTC added for $username${NC}"
}

add_vless_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Username: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_vless.uri" ]; then echo -e "${YELLOW}VLESS exists${NC}"; return 1; fi
    mkdir -p "$(dirname "$VLESS_USERS_FILE")"
    if [ ! -f "$VLESS_USERS_FILE" ]; then echo '{}' > "$VLESS_USERS_FILE"; fi
    local uuid
    uuid=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid || openssl rand -hex 16)
    jq --arg user "$username" --arg uuid "$uuid" '.[$user] = $uuid' "$VLESS_USERS_FILE" > /tmp/vless_users.tmp && mv /tmp/vless_users.tmp "$VLESS_USERS_FILE"
    update_xray_config
    local link="vless://${uuid}@${VLESS_HOST}:${VLESS_PORT}?security=reality&type=xhttp&path=%2F&sni=1.1.1.1&fp=chrome&pbk=${VLESS_PUBLIC_KEY}&sid=${VLESS_SHORT_ID}&spx=%2Fdns-query%2F#${username}"
    echo "$link" > "$BASE_DIR/$username/${username}_vless.uri"
    generate_qr "$link" "$BASE_DIR/$username/${username}_vless.png"
    echo -e "${GREEN}VLESS added for $username${NC}"
}

# CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    init
    if [ $# -gt 0 ]; then
        case "$1" in
            add_user|del_user|add_hy2_user|add_awg_user|add_naive_user|add_mieru_user|add_olcrtc_user|add_vless_user)
                "$1" "$2" ;;
            list_users|list) list_users ;;
            remove_protocol) remove_protocol "$3" "$2" ;;
            *)
                echo "Usage: $0 {add_user|del_user|list_users|remove_protocol|add_hy2_user|add_awg_user|add_naive_user|add_mieru_user|add_olcrtc_user|add_vless_user} [username]"
                exit 1 ;;
        esac
        exit $?
    fi
fi

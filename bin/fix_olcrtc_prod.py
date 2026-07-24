#!/usr/bin/env python3
"""Fix add_olcrtc_user on prod: yaml -> json with claims_user/claims_pass."""
filepath = '/root/proxy_manager.sh'
with open(filepath, 'r') as f:
    content = f.read()

old_func = '''add_olcrtc_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Username: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_olcrtc.yaml" ]; then echo -e "${YELLOW}olcRTC exists${NC}"; return 1; fi
    local password=$(openssl rand -hex 12)
    mkdir -p "$(dirname "$OLRTC_USERS_FILE")"
    if [ ! -f "$OLRTC_USERS_FILE" ]; then echo '{}' > "$OLRTC_USERS_FILE"; fi
    jq --arg user "$username" --arg pass "$password" '.[$user] = $pass' "$OLRTC_USERS_FILE" > /tmp/olcrtc_users.tmp && mv /tmp/olcrtc_users.tmp "$OLRTC_USERS_FILE"
    cat > "$BASE_DIR/$username/${username}_olcrtc.yaml" << OLRTC_EOF
mode: cnc
auth:
  provider: jitsi
net:
  transport: datachannel
  dns: 8.8.8.8:53
  ice: $OLRTC_ICE
server: ws://${SERVER_DOMAIN}:30001
room:
  id: $OLRTC_ROOM_URL
crypto:
  key: "$OLRTC_CRYPTO_KEY"
socks:
  host: 127.0.0.1
  port: 1082
data: /tmp/olcrtc_data
claims:
  user: $username
  pass: $password
OLRTC_EOF'''

new_func = '''add_olcrtc_user() {
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
OLRTC_EOF'''

if old_func in content:
    content = content.replace(old_func, new_func)
    with open(filepath, 'w') as f:
        f.write(content)
    print('Fixed: add_olcrtc_user now creates .json with claims')
else:
    # Try to find just the file check line
    if '_olcrtc.yaml' in content and 'add_olcrtc_user' in content:
        content = content.replace('${username}_olcrtc.yaml', '${username}_olcrtc.json')
        # Replace yaml heredoc with json
        yaml_block = '''    cat > "$BASE_DIR/$username/${username}_olcrtc.yaml" << OLRTC_EOF
mode: cnc
auth:
  provider: jitsi
net:
  transport: datachannel
  dns: 8.8.8.8:53
  ice: $OLRTC_ICE
server: ws://${SERVER_DOMAIN}:30001
room:
  id: $OLRTC_ROOM_URL
crypto:
  key: "$OLRTC_CRYPTO_KEY"
socks:
  host: 127.0.0.1
  port: 1082
data: /tmp/olcrtc_data
claims:
  user: $username
  pass: $password
OLRTC_EOF'''
        json_block = '''    cat > "$BASE_DIR/$username/${username}_olcrtc.json" << OLRTC_EOF
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
OLRTC_EOF'''
        content = content.replace(yaml_block, json_block)
        # Fix users.json init
        content = content.replace(
            'if [ ! -f "$OLRTC_USERS_FILE" ]; then echo \'{}\' > "$OLRTC_USERS_FILE"; fi',
            'python3 -c "import json; f=\'$OLRTC_USERS_FILE\'; open(f,\'a\').close(); json.load(open(f))" 2>/dev/null || echo \'{}\' > "$OLRTC_USERS_FILE"'
        )
        with open(filepath, 'w') as f:
            f.write(content)
        print('Fixed with fallback method')
    else:
        print('Pattern not found')

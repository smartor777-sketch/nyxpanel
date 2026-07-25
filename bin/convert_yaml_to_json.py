#!/usr/bin/env python3
"""Convert existing _olcrtc.yaml to _olcrtc.json with claims on prod."""
import os
import json
import glob

BASE_DIR = '/root/proxy_users'
OLRTC_ROOM_URL = 'https://meet.egovm.ru/nyx-<YOUR_DOMAIN>'
OLRTC_CRYPTO_KEY = '<REPLACE_WITH_YOUR_KEY>'

for user_dir in glob.glob(f'{BASE_DIR}/*'):
    if not os.path.isdir(user_dir):
        continue
    username = os.path.basename(user_dir)
    yaml_path = f'{user_dir}/{username}_olcrtc.yaml'
    json_path = f'{user_dir}/{username}_olcrtc.json'
    uri_path = f'{user_dir}/{username}_olcrtc.uri'
    
    if os.path.exists(yaml_path) and not os.path.exists(json_path):
        # Read password from users.json
        users_file = '/etc/olcrtc/users.json'
        password = ''
        if os.path.exists(users_file):
            with open(users_file) as f:
                users = json.load(f)
                password = users.get(username, '')
        
        config = {
            "storage_id": "olcboxme-main",
            "name": "NYX Main",
            "endpoint": {
                "room_id": OLRTC_ROOM_URL,
                "key": OLRTC_CRYPTO_KEY
            },
            "auth_provider": "jitsi",
            "transport": {
                "type": "datachannel"
            },
            "claims_user": username,
            "claims_pass": password
        }
        with open(json_path, 'w') as f:
            json.dump(config, f, indent=2)
        os.remove(yaml_path)
        print(f'Converted: {username} (yaml -> json with claims)')
    elif os.path.exists(json_path):
        print(f'Already json: {username}')
    else:
        print(f'No olcRTC config: {username}')

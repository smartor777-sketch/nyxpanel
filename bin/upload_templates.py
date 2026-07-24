#!/usr/bin/env python3
"""Upload templates to prod via base64 encoding to preserve UTF-8."""
import base64
import subprocess
import os

FILES = ['self.html', 'self_admin.html', 'index.html']
LOCAL_DIR = r'C:\Users\Alex\nyxpanel\bin'
PROD_HOST = 'root@31.76.8.29'
PROD_DIR = '/opt/proxy-panel/templates'

for fname in FILES:
    local_path = os.path.join(LOCAL_DIR, fname)
    with open(local_path, 'rb') as f:
        data = f.read()
    b64 = base64.b64encode(data).decode('ascii')
    
    # Upload base64 string to prod, then decode there
    cmd = f'echo {b64} | base64 -d > {PROD_DIR}/{fname}'
    
    # Use plink to run the command on prod
    full_cmd = ['plink', '-batch', '-pw', 'master2000', PROD_HOST, cmd]
    result = subprocess.run(full_cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        print(f'Error uploading {fname}: {result.stderr}')
    else:
        print(f'Uploaded {fname}: {len(data)} bytes')

print('Done')

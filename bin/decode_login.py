#!/usr/bin/env python3
import base64
import sys

b64 = sys.stdin.read().strip()
data = base64.b64decode(b64)
with open('/opt/proxy-panel/templates/self_login.html', 'wb') as f:
    f.write(data)
print(f'Written {len(data)} bytes')
# Verify
with open('/opt/proxy-panel/templates/self_login.html', 'r', encoding='utf-8') as f:
    c = f.read()
for line in c.split('\n'):
    if 'ru:' in line and 'username' in line:
        print(f'Verify: {line.strip()}')

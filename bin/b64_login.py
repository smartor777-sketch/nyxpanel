#!/usr/bin/env python3
import base64

with open('/opt/proxy-panel/templates/self_login.html', 'rb') as f:
    data = f.read()
print(base64.b64encode(data).decode())

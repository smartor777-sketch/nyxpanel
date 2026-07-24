#!/usr/bin/env python3
with open('/opt/proxy-panel/templates/self_login.html', 'r', encoding='utf-8') as f:
    c = f.read()
for line in c.split('\n'):
    if 'ru:' in line and 'username' in line:
        print(line.strip())

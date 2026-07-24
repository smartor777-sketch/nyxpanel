#!/usr/bin/env python3
filepath = '/root/proxy_manager.sh'
with open(filepath, 'r') as f:
    content = f.read()
content = content.replace('${user}_olcrtc.yaml', '${user}_olcrtc.json')
with open(filepath, 'w') as f:
    f.write(content)
with open(filepath, 'r') as f:
    c = f.read()
print(f'yaml: {c.count("_olcrtc.yaml")}, json: {c.count("_olcrtc.json")}')

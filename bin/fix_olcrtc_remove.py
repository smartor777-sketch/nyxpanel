#!/usr/bin/env python3
"""Fix remove_protocol olcrtc: yaml -> json."""
filepath = '/root/proxy_manager.sh'
with open(filepath, 'r') as f:
    content = f.read()

# Fix remove_protocol olcrtc section
content = content.replace(
    '${username}_olcrtc.yaml',
    '${username}_olcrtc.json'
)

with open(filepath, 'w') as f:
    f.write(content)

# Verify
with open(filepath, 'r') as f:
    c = f.read()
yaml_count = c.count('_olcrtc.yaml')
json_count = c.count('_olcrtc.json')
print(f'Remaining .yaml references: {yaml_count}')
print(f'.json references: {json_count}')

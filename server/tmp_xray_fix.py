#!/usr/bin/env python3
"""Enable access log in xray config."""
import json

with open('/usr/local/etc/xray/config.json') as f:
    c = json.load(f)

c['log']['loglevel'] = 'debug'
c['log']['access'] = '/var/log/xray/access.log'
c['log']['error'] = '/var/log/xray/error.log'

with open('/usr/local/etc/xray/config.json', 'w') as f:
    json.dump(c, f, indent=2)

print('xray config updated')

#!/usr/bin/env python3
import sqlite3

files = {
    'self.html': '/opt/proxy-panel/templates/self.html',
    'self_admin.html': '/opt/proxy-panel/templates/self_admin.html',
    'index.html': '/opt/proxy-panel/templates/index.html',
}

for name, path in files.items():
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    has_inf = '\u221e' in content
    has_tiyu = '\u0442\u0418\u042e' in content
    has_current = 'currentPeriod' in content
    has_days2 = 'data-days="2"' in content
    print(f'{name}: inf={has_inf} tiyu={has_tiyu} currentPeriod={has_current} days2={has_days2}')

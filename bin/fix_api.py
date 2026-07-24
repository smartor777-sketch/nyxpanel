#!/usr/bin/env python3
"""Fix api_traffic: when days=0 and name is provided, still filter by username."""
filepath = '/opt/proxy-panel/app.py'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

old = '''    if days == 0:
        rows = db.execute(
            "SELECT username, date, protocol, bytes_up, bytes_down FROM daily_traffic ORDER BY date, username"
        ).fetchall()
    elif name:'''

new = '''    if days == 0:
        if name:
            rows = db.execute(
                "SELECT username, date, protocol, bytes_up, bytes_down FROM daily_traffic WHERE username = ? ORDER BY date",
                (name,)
            ).fetchall()
        else:
            rows = db.execute(
                "SELECT username, date, protocol, bytes_up, bytes_down FROM daily_traffic ORDER BY date, username"
            ).fetchall()
    elif name:'''

if old in content:
    content = content.replace(old, new)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)
    print('Fixed: days=0 now filters by username when name is provided')
else:
    print('Pattern not found - may already be fixed or code has changed')

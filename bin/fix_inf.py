#!/usr/bin/env python3
"""Fix infinity symbol in self.html on server."""
import sys
import os

filepath = '/opt/proxy-panel/templates/self.html'
try:
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    if 'тИЮ' in content:
        content = content.replace('тИЮ', '∞')
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'Fixed: replaced тИЮ with ∞')
    elif '∞' in content:
        print('Already correct (∞ present)')
    else:
        print('Neither тИЮ nor ∞ found')
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)

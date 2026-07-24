#!/usr/bin/env python3
"""Fix Russian encoding in self_login.html on prod."""
filepath = '/opt/proxy-panel/templates/self_login.html'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

old = "ru: { username: '\u0412\u0435\u0440\u043d\u0438\u0442\u0435\u043b\u044c\u043d\u043e \u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044c', password: '\u041f\u0430\u0440\u043e\u043b\u044c', signin: '\u0412\u043e\u0439\u0442\u0438' }"
if old in content:
    print('Already correct')
else:
    # Try to find broken encoding
    broken_patterns = [
        ('\\u0412\\u0435\\u0440\\u043d\\u0438\\u0442\\u0435\\u043b\\u044c\\u043d\\u043e \\u043f\\u043e\\u043b\\u044c\\u0437\\u043e\\u0432\\u0430\\u0442\\u0435\\u043b\\u044c', 'correct unicode'),
    ]
    # Check for mojibake
    if '\\u0412\\u0435\\u0440' in content or '╨' in content:
        print('Found broken encoding, fixing...')
        # Replace the entire _t block
        content = content.replace(
            "ru: { username: '\\u0412\\u0435\\u0440\\u043d\\u0438\\u0442\\u0435\\u043b\\u044c\\u043d\\u043e \\u043f\\u043e\\u043b\\u044c\\u0437\\u043e\\u0432\\u0430\\u0442\\u0435\\u043b\\u044c', password: '\\u041f\\u0430\\u0440\\u043e\\u043b\\u044c', signin: '\\u0412\\u043e\\u0439\\u0442\\u0438' }",
            "ru: { username: '\u0418\u043c\u044f \u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044f', password: '\u041f\u0430\u0440\u043e\u043b\u044c', signin: '\u0412\u043e\u0439\u0442\u0438' }"
        )
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print('Fixed')
    else:
        print(f'Unknown encoding state')
        # Show relevant line
        for line in content.split('\n'):
            if 'ru:' in line and 'username' in line:
                print(f'Found: {line.strip()[:100]}')

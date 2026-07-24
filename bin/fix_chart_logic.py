import os

for template in ('self.html', 'self_admin.html'):
    p = '/opt/proxy-panel/templates/' + template
    c = open(p, encoding='utf-8').read()

    # Replace summary mode: only for days=0, not for partial data
    old = "if (days === '0' || (needDays > 0 && actualDays < needDays / 2)) {"
    new = "if (days === '0') {"
    if old in c:
        c = c.replace(old, new)
        open(p, 'w', encoding='utf-8').write(c)
        print(f'{template}: fixed summary logic')
    elif new in c:
        print(f'{template}: already fixed')
    else:
        print(f'{template}: pattern not found')

print('Done')
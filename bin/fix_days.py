import os
d = '/opt/proxy-panel/templates'
for f in ('self.html', 'self_admin.html', 'index.html'):
    p = os.path.join(d, f)
    c = open(p, encoding='utf-8').read()
    c = c.replace('data-days="1"', 'data-days="2"').replace('data-days="7"', 'data-days="14"').replace('data-days="30"', 'data-days="60"')
    open(p, 'w', encoding='utf-8').write(c)
    print(f + ' done')
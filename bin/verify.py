for f in ('self.html', 'self_admin.html', 'index.html'):
    c = open('/opt/proxy-panel/templates/' + f, encoding='utf-8').read()
    print(f + ':')
    print('  data-days=2:', 'data-days="2"' in c)
    print('  data-days=14:', 'data-days="14"' in c)
    print('  data-days=60:', 'data-days="60"' in c)
    print('  Активен:', 'Активен' in c)
    print('  ∞:', '∞' in c)
    if 'self.html' in f:
        print('  actualDays:', 'actualDays' in c)
        print('  borderRadius:', 'borderRadius' in c)
    print()
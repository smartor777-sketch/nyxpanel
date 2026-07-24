p = '/opt/proxy-panel/templates/self.html'
c = open(p, encoding='utf-8').read()
i = c.find('traffic_limit_bytes')
print('limit section:', repr(c[i:i+120]))
i = c.find('\u221e')
if i >= 0:
    print('found infinity char at', i, ':', repr(c[i-10:i+10]))
else:
    print('infinity char not found')
    # Check for corrupted versions
    for s in ['тИЮ', 'â', '∞']:
        i = c.find(s)
        if i >= 0:
            print(f'found "{s}" at', i, ':', repr(c[i-10:i+30]))
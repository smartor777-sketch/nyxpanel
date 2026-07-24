p = '/opt/proxy-panel/templates/self.html'
c = open(p, encoding='utf-8').read()
i = c.find('active:')
print('repr:', repr(c[i:i+50]))
print('hex:', c[i:i+50].encode('utf-8').hex())
# Check if it's double-encoded
try:
    c2 = c[i:i+50].encode('latin-1').decode('utf-8')
    print('latin1->utf8:', repr(c2))
except:
    print('not latin1-decodeable')
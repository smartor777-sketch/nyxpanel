p = '/opt/proxy-panel/templates/self.html'
c = open(p, encoding='utf-8').read()
i = c.find('ru:')
print('ru: at', i)
chunk = c[i:i+300]
print('repr:', repr(chunk))
# Try the first Russian word
for word in ['Активен', 'Отключён', 'Гайд']:
    if word in c:
        j = c.find(word)
        print(f'Found "{word}" at', j, 'hex:', c[j:j+len(word)].encode('utf-8').hex())
    else:
        # Check for double-encoded version
        double = word.encode('utf-8').decode('latin-1')
        if double in c:
            j = c.find(double)
            print(f'Found DOUBLE-ENCODED "{word}" at', j)
        else:
            print(f'NOT found: "{word}"')
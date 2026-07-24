p = '/tmp/login.html'
c = open(p, encoding='utf-8').read()
print('page length:', len(c))
print('data-days="2":', 'data-days="2"' in c)
print('data-days="14":', 'data-days="14"' in c)
print('data-days="60":', 'data-days="60"' in c)
print('data-days="0":', 'data-days="0"' in c)
print('actualDays (summary mode):', 'actualDays' in c)
print()

i = c.find('ru:')
if i > 0:
    chunk = c[i:i+400]
    # Find the first Russian string in the ru block
    for line in chunk.split('\n'):
        line = line.strip()
        if line.startswith('active:') or line.startswith('today:') or line.startswith('usage:') or line.startswith('traffic:'):
            print('i18n:', line)
else:
    # Check the rendered output for Russian
    for word in ['Активен', 'Сегодня', 'Трафик', 'Неделя', 'Месяц', 'Загрузка', 'Скачивание', 'Всё', '∞']:
        if word in c:
            i = c.find(word)
            print(f'Rendered "{word}" found at', i)
        else:
            print(f'Rendered "{word}" NOT found')

# Check for mojibake
for bad in ['╨Р╨║╤В╨╕╨▓╡╨╜', '╨в╤А╨░╤Д╨╕╨║', 'тИЮ']:
    if bad in c:
        print(f'MOJIBAKE found: {bad}')
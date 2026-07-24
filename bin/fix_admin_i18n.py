import re

def fix_mojibake(text):
    """Convert double-encoded UTF-8 (mojibake) to proper UTF-8"""
    try:
        return text.encode('latin-1').decode('utf-8')
    except:
        return text

p = 'C:/Users/Alex/nyxpanel/server/templates/self_admin.html'
c = open(p, encoding='utf-8').read()

# Find the ru block
i = c.find('ru: {')
j = c.find('en: {', i)
ru_block = c[i:j]

# Fix all Russian text values in the ru block
# Match key: 'value' and fix the value
def fix_ru_values(match):
    key = match.group(1)
    val = match.group(2)
    fixed = fix_mojibake(val)
    return f"{key}: '{fixed}'"

fixed_ru = re.sub(r"(\w+):\s*'((?:[^'\\]|\\.)*)'", fix_ru_values, ru_block)

# Also fix keys that might have emoji unicode escapes like \u2705 or \u{1F517}
# These are already correct in JS, leave them as-is

c = c[:i] + fixed_ru + c[j:]
open(p, 'w', encoding='utf-8').write(c)

print('Fixed admin i18n in server/templates/self_admin.html')

# Verify
v = open(p, encoding='utf-8').read()
check_words = ['Гайд', 'Выйти', 'Админ', 'Добавить пользователя', 'Пользователи', 'Статус', 'Срок', 'Пароль', 'Действ.', 'Экспорт', 'Сегодня', 'Неделя', 'Месяц', 'Всё', 'Загрузка', 'Скачивание', 'Всего']
all_ok = True
for w in check_words:
    if w in v:
        print(f'  OK: {w}')
    else:
        print(f'  MISSING: {w}')
        all_ok = False
print('All good!' if all_ok else 'Some fixes failed')

# Also copy to panel/proxy-panel/templates/
p2 = 'C:/Users/Alex/nyxpanel/panel/proxy-panel/templates/self_admin.html'
open(p2, 'w', encoding='utf-8').write(v)
print('Copied to panel/proxy-panel/templates/')
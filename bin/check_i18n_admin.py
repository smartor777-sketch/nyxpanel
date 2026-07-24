c = open('/opt/proxy-panel/templates/self_admin.html', encoding='utf-8').read()

# Extract i18n keys from HTML
import re
html_keys = set(re.findall(r'data-i18n="([^"]+)"', c))

# Extract ru dictionary keys
i = c.find('ru: {')
j = c.find('en: {', i)
ru_block = c[i:j]
ru_keys = set()
for line in ru_block.split('\n'):
    line = line.strip().rstrip(',').strip()
    if ':' in line and "'" in line:
        k = line.split(':')[0].strip().strip("'")
        ru_keys.add(k)

# Also get en keys for comparison
en_block = c[j:c.find('};', j)]
en_keys = set()
for line in en_block.split('\n'):
    line = line.strip().rstrip(',').strip()
    if ':' in line and "'" in line:
        k = line.split(':')[0].strip().strip("'")
        en_keys.add(k)

print('=== HTML data-i18n keys used ===')
print(sorted(html_keys))

print('\n=== Keys defined in ru: ===')
print(sorted(ru_keys))

print('\n=== Keys defined in en: ===')
print(sorted(en_keys))

print('\n=== MISSING from ru: ===')
missing = html_keys - ru_keys
for k in sorted(missing):
    print(f'  {k}')

print('\n=== MISSING from en: ===')
missing_en = html_keys - en_keys
for k in sorted(missing_en):
    print(f'  {k}')

# Also print the full ru block to see its current state
print('\n=== Current ru block ===')
for line in ru_block.split('\n'):
    l = line.strip()
    if l:
        print(f'  {l}')
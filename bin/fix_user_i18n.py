import os

p = '/opt/proxy-panel/templates/self.html'
c = open(p, encoding='utf-8').read()

# Find ru block and replace with proper UTF-8
i = c.find('ru: {')
j = c.find('en: {', i)
if i > 0 and j > i:
    new_ru = """  ru: {
    active: 'Активен', disabled: 'Отключён', expires: 'Истекает', noExpiry: 'Без срока',
    guide: 'Гайд', support: 'Поддержка',
    signOut: 'Выйти',
    usage: 'Использование', totalTraffic: 'Всего трафика', limit: 'Лимит',
    configs: 'Конфигурации', config: 'Config', subscription: 'Подписка',
    copyUrl: '\\u{1F517} Скопировать URL', noConfigs: 'Нет доступных конфигураций',
    traffic: 'Трафик', today: 'Сегодня', week: 'Неделя', month: 'Месяц', all: 'Всё',
    upload: 'Загрузка', download: 'Скачивание', copied: '\\u2705 Скопировано!',
    currentPeriod: 'Текущий', prevPeriod: 'Прошлый'
  },"""
    c = c[:i] + new_ru + c[j:]
    open(p, 'w', encoding='utf-8').write(c)
    # Verify
    v = open(p, encoding='utf-8').read()
    if 'Активен' in v and 'Загрузка' in v and 'currentPeriod' in v:
        print('self.html: fixed OK')
    else:
        print('self.html: verify FAILED')
else:
    print('self.html: ru block not found')

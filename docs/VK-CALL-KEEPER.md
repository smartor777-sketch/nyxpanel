# VK Call Keeper — План

Расположение в проекте: `server/vk-call-keeper/`

## Концепция
Скрипт периодически (раз в ~5 минут) подключается к VK-звонку по ссылке, держит соединение ~10-30 секунд, отключается. Таймаут VK-звонка после выхода всех участников — 5-10 минут, поэтому звонок не закрывается.

## Архитектура

### Компоненты
1. **vk-call-keeper.py** — основной скрипт (Playwright)
2. **systemd timer** — запуск каждые 5 минут + рандомизация
3. **Конфиг** — ссылка на звонок, credentials

### Поток работы
```
cron/timer → vk-call-keeper.py
  1. Читает конфиг (ссылка на звонок, аккаунт VK)
  2. Запускает headless Chromium (Playwright)
  3. Заходит на ссылку звонка
  4. Ждёт 10-30 секунд (случайное время)
  5. Выходит из звонка
  6. Закрывает браузер
  7. Логирует результат
```

### Рандомизация
- Интервал: 5 минут ± 2 минуты (3-7 минут)
- Время в звонке: 2-5 минут (случайно, как реальный звонок)
- Задержка перед входом: 0-30 секунд

### Конфиг (vk_call_keeper.json)
```json
{
  "call_url": "https://vk.com/video-calls/...",
  "vk_cookies": "cookies.json",
  "min_interval_sec": 180,
  "max_interval_sec": 420,
  "min_hold_sec": 120,
  "max_hold_sec": 300,
  "headless": true,
  "log_file": "/var/log/vk-call-keeper.log"
}
```

### Playwright скрипт (псевдокод)
```python
async def keep_call():
    browser = await playwright.chromium.launch(headless=True)
    context = await browser.new_context()
    
    # Загрузить куки VK
    cookies = json.load(open("cookies.json"))
    await context.add_cookies(cookies)
    
    page = await context.new_page()
    await page.goto(call_url)
    
    # Ждать входа в звонок
    await page.wait_for_selector("[data-join-button]", timeout=30000)
    await page.click("[data-join-button]")
    
    # Держать соединение случайное время (как реальный звонок)
    hold_time = random.randint(min_hold, max_hold)  # 2-5 минут
    await asyncio.sleep(hold_time)
    
    # Выйти
    await page.click("[data-leave-button]")
    await browser.close()
```

### Systemd timer
```ini
# /etc/systemd/system/vk-call-keeper.service
[Unit]
Description=VK Call Keeper
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/vk-call-keeper/keeper.py
Restart=on-failure
RestartSec=60

# /etc/systemd/system/vk-call-keeper.timer
[Unit]
Description=VK Call Keeper Timer

[Timer]
OnBootSec=60
OnUnitActiveSec=300
RandomizedDelaySec=120
AccuracySec=30

[Install]
WantedBy=timers.target
```

### Риски
1. **Блокировка VK** — VK может обнаружить паттерн и заблокировать аккаунт
   - Решение: рандомизация, имитация реального поведения (нажатия, движение мыши)
2. **Изменение UI VK** — селекторы могут измениться
   - Решение: регулярное обновление, мониторинг ошибок
3. **Нестабильность** — звонок может не загрузиться
   - Решение: retry с экспоненциальной задержкой, уведомления в Telegram

### Telegram уведомления
- Успешное подключение
- Ошибка подключения (3+ раза подряд)
- Блокировка аккаунта

### Деплой
1. Установить Playwright на сервер: `pip install playwright && playwright install chromium`
2. Положить скрипт в `/opt/vk-call-keeper/`
3. Создать systemd service + timer
4. Настроить куки VK (один раз)
5. Запустить: `systemctl enable --now vk-call-keeper.timer`

---

## Альтернатива: aiortc (~10MB RAM)

Почти готовый Playwright-вариант дорабатывается минимально. Но есть более экономный вариант — **aiortc** (чистый Python WebRTC без браузера).

### Почему aiortc
- **~10MB RAM** вместо 100-200MB (Playwright + Chromium)
- Не нужен headless-браузер
- Прямое подключение к WebRTC-потоку VK
- Быстрый старт (нет загрузки браузера)

### Сложности
- VK использует **собственный WebRTC-протокол** (не стандартный SDP/ICE)
- Нужно reverse-engineer API VK Video Calls:
  - Авторизация через куки
  - Получение `room_id` и `participant_id` из ссылки звонка
  - WebRTC signaling через VK WebSocket
  - Обработка SRTP/DTLS
- VK может менять протокол без предупреждения

### План реализации
```
1. Исследовать трафик VK Video Calls (F12 → Network → WebSocket)
2. Определить signaling protocol:
   - Как VK передаёт SDP offer/answer
   - Как происходит ICE exchange
   - Как VK аутентифицирует участников
3. Реализовать на aiortc:
   - Авторизация (cookies → session)
   - Join call (GET room info → WebRTC connect)
   - Keep alive (отправлять keepalive packets)
   - Leave call (корректное закрытие)
4. Интеграция с WDTT:
   - Скрипт создаёт "фейкового" участника
   - WDTT видит активный звонок
   - Трафик идёт через WebRTC канал
```

### Структура проекта
```
/opt/vk-call-keeper/
├── keeper.py           # Основной entry point
├── vk_calls/
│   ├── auth.py         # Авторизация VK (cookies → session)
│   ├── signaling.py    # WebRTC signaling через VK WebSocket
│   ├── webrtc.py       # aiortc подключение
│   └── protocol.py     # Протокол VK Video Calls (reverse-engineered)
├── config.json
├── cookies.json
└── requirements.txt    # aiortc, aiohttp, websockets
```

### Деплой
1. `pip install aiortc aiohttp websockets`
2. Положить скрипт в `/opt/vk-call-keeper/`
3. Настроить куки VK (один раз)
4. Экспериментировать на **отдельном аккаунте VK**

### Мониторинг
- Telegram-уведомления при ошибках
- Логирование всех signaling-событий
- Метрики: uptime звонка, latency, пакеты丢了

### Риски aiortc
1. **Reverse engineering** — VK не документирует протокол, всё через анализ трафика
2. **Блокировка** — VK может детектировать нестандартные WebRTC-клиенты
3. **Обновления протокола** — VK может изменить signaling без предупреждения
4. **Сложность отладки** — нет готовых инструментов для анализа VK WebRTC

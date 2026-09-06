# WDTT Telegram Bot — Спецификация

## 1. Обзор

**WDTT Bot** — Telegram-бот для управления пользователями WDTT VPN-сервера. Заменяет встроенный Go-бот в `wdtt-server`, добавляя расширенную функциональность и UX.

**Стек:** Python 3.11+ / `python-telegram-bot` v20+

**Сервер:** prod (87.120.186.100)

---

## 2. Архитектура

```
Telegram User ←→ WDTT Bot (Python) ←→ passwords.json ←→ WDTT Server (Docker)
                                         ↓
                                   docker compose restart
```

**Принцип работы:**
1. Бот читает/пишет `passwords.json` на хосте
2. После изменений — перезапускает контейнер `wdtt-vpn`
3. Сервер перезагружает пароли из JSON при старте

**Путь к конфигу:**
```
/opt/proxy-turn-vk-android-server-fix/docker-wdtt/config/passwords.json
```

---

## 3. Роли и доступ

| Роль | Описание | Определение |
|------|----------|-------------|
| **Admin** | Владелец сервера (один человек) | Telegram ID == ADMIN_ID в `.env` |
| **User** | Подключённый пользователь | Любой другой Telegram ID |

### Проверка роли

```python
def is_admin(user_id: int) -> bool:
    return user_id == ADMIN_ID

async def handle_command(update, context):
    if not is_admin(update.effective_user.id):
        await update.message.reply_text("⛔ Нет доступа")
        return
    # ... admin logic
```

### Разные меню

**Admin `/start`:**
```
🤖 WDTT VPN Manager

👥 Управление:
/new — Новый пользователь
/list — Список пользователей
/stats — Статистика
/broadcast — Рассылка

ℹ️ Информация:
/info — Инструкция для юзера
```

**User `/start`:**
```
👋 Привет! Я помогу подключиться к VPN.

📖 Как подключиться: /guide
❓ Помощь: /help
```

---

## 4. Команды

### 4.1. Admin команды

| Команда | Описание | Аргументы |
|---------|----------|-----------|
| `/start` | Главное меню (admin) | — |
| `/new` | Создать нового пользователя | — (далее по диалогу) |
| `/list` | Список всех пользователей | — |
| `/info <пароль>` | Инструкция для пользователя | Пароль |
| `/delete <пароль>` | Удалить пользователя | Пароль |
| `/deactivate <пароль>` | Деактивировать (временно) | Пароль |
| `/activate <пароль>` | Активировать обратно | Пароль |
| `/stats` | Общая статистика | — |
| `/broadcast <текст>` | Рассылка всем пользователям | Текст |

### 4.2. User команды

| Команда | Описание |
|---------|----------|
| `/start` | Приветствие + краткая инструкция |
| `/help` | Список команд пользователя |
| `/guide` | Подробная инструкция подключения |

### 4.3. Обработка неизвестных команд

```python
async def unknown_command(update, context):
    if is_admin(update.effective_user.id):
        await update.message.reply_text(
            "❓ Неизвестная команда. Используйте /start"
        )
    else:
        await update.message.reply_text(
            "❓ Неизвестная команда. Используйте /help"
        )
```

---

## 5. Диалог создания пользователя (`/new`)

```
Admin: /new

Bot: 📅 Срок действия (дней):
      [1] [7] [30] [90] [365]

Admin: нажимает [30]

Bot: 🔑 VK хеш звонка:
      _Введите хеш из ссылки vk.com/call/join/XXXXX_

Admin: вставляет хэш

Bot: ✅ Пользователь создан!
      ─────────────────
      🔑 Пароль: AbCdEf1234567890
      ⏰ Действует: 30 дней (до 01.10.2026)
      🔗 Хэш: XXXXXXXXX
      ─────────────────
      📱 Инструкция для пользователя:
      /info AbCdEf1234567890
```

---

## 6. Список пользователей (`/list`)

```
Admin: /list

Bot: 👥 Пользователи (3/10):
      ─────────────────────────

      🟢 AbCdEf1234567890
         ⏰ 28 дней | 📱 Привязан | 📊 1.2 GB

      🔴 XyZ9876543210wq
         ⏰ ИСТЁК | ❌ Неактивен

      🟡 QwErTy123456789
         ⏰ 5 дней | 📱 Ожидает

      ─────────────────────────
      [➕ Новый] [📊 Статистика]
```

**Inline-кнопки для каждого пользователя:**
- 🔍 Подробнее
- ⏸ Деактивировать / ✅ Активировать
- 📱 Отвязать устройство
- 🗑 Удалить

---

## 7. Инструкция для пользователя (`/info`)

```
Admin: /info AbCdEf1234567890

Bot: 📱 Инструкция для подключения
      ═══════════════════════════

      🔑 Пароль: AbCdEf1234567890
      🌐 Адрес: 87.120.186.100
      🔌 Порты: 56000, 56001

      ─── Как подключиться ───

      1️⃣ Откройте VK и создайте звонок
         в группе или диалоге

      2️⃣ Скопируйте ссылку приглашения
         vk.com/call/join/XXXXXXXXX

      3️⃣ Извлеките хэш из ссылки
         (после /join/)

      4️⃣ Откройте WDTT / PWDTT

      5️⃣ Введите:
         • Адрес: 87.120.186.100
         • Порт DTLS: 56000
         • Порт WG: 56001
         • Пароль: AbCdEf1234567890
         • Хэш: XXXXXXXXX

      6️⃣ Нажмите "Подключить"

      ─── Ссылка для быстрого подключения ───

      `wdtt://87.120.186.100:56000:56001:9000:AbCdEf1234567890:XXXXXXX`

      ⚠️ Важно:
      • Не закрывайте звонок в VK
      • Хэш можно менять в настройках
      • При проблемах переподключитесь
```

---

## 8. Статистика (`/stats`)

```
Admin: /stats

Bot: 📊 Статистика сервера
      ════════════════════

      👥 Пользователей: 3/10
      🟢 Активных: 2
      🔴 Неактивных: 1

      📈 Трафик сегодня:
      • Скачано: 15.3 GB
      • Отдано: 2.1 GB

      📈 Трафик всего:
      • Скачано: 142.7 GB
      • Отдано: 28.4 GB

      🖥 Сервер:
      • Uptime: 15 дней
      • WG-порт: 56001
      • DTLS-порт: 56000
```

---

## 9. Рассылка (`/broadcast`)

```
Admin: /broadcast Завтра плановые работы с 3:00 до 5:00

Bot: 📨 Рассылка 3 пользователям:
      "Завтра плановые работы с 3:00 до 5:00"

      Отправить? [Да] [Нет]

Admin: [Да]

Bot: ✅ Отправлено 3/3 пользователям
```

---

## 10. Формат passwords.json

```json
{
  "main_password": "yO3aN0cU6efK",
  "admin_id": "1139341866",
  "bot_token": "8855687995:AAFZtR-te0HGMZWfisuDVFaJ7HOQ24G7PnE",
  "passwords": {
    "AbCdEf1234567890": {
      "expires_at": 1790780232,
      "vk_hash": "XXXXXXXXX",
      "ports": "56000,56001,9000",
      "device_id": "ca1917a0-2f92-489e-98cb-2ff90c722d8e",
      "is_deactivated": false,
      "down_bytes": 1258291200,
      "up_bytes": 214748364
    }
  },
  "devices": {
    "ca1917a0-2f92-489e-98cb-2ff90c722d8e": {
      "device_id": "ca1917a0-2f92-489e-98cb-2ff90c722d8e",
      "ip": "10.66.66.2",
      "priv_key": "...",
      "pub_key": "..."
    }
  }
}
```

---

## 11. Перезапуск контейнера

После каждого изменения `passwords.json` бот должен перезапускать контейнер:

```python
import subprocess

def restart_wdtt():
    subprocess.run([
        "docker", "compose", "-f",
        "/opt/proxy-turn-vk-android-server-fix/docker-wdtt/docker-compose.yml",
        "restart"
    ], check=True)
```

**Время перезапуска:** 1-2 секунды
**Влияние на пользователей:** кратковременный разрыв (автоматическое переподключение)

---

## 12. Безопасность

| Мера | Описание |
|------|----------|
| Admin ID | Проверка Telegram ID из `.env` |
| Остальные | Бот игнорирует сообщения не от admin |
| Пароли | Не отображаются полностью в логах |
| Токен | Хранится в `.env`, не в коде |

---

## 13. Структура проекта

```
/opt/wdtt-bot/
├── bot.py              # Основной файл бота
├── config.py           # Конфигурация (путь к JSON, admin ID)
├── handlers/
│   ├── __init__.py
│   ├── start.py        # /start, /help
│   ├── user.py         # /new, /list, /info, /delete
│   ├── stats.py        # /stats
│   └── broadcast.py    # /broadcast
├── utils/
│   ├── __init__.py
│   ├── db.py           # Чтение/запись passwords.json
│   ├── docker.py       # Перезапуск контейнера
│   └── formatter.py    # Форматирование сообщений
├── requirements.txt
├── .env                # BOT_TOKEN, ADMIN_ID
└── wdtt-bot.service    # Systemd сервис
```

---

## 14. Автозапуск

```ini
# /etc/systemd/system/wdtt-bot.service
[Unit]
Description=WDTT Telegram Bot
After=network.target docker.service

[Service]
Type=simple
WorkingDirectory=/opt/wdtt-bot
ExecStart=/opt/wdtt-bot/venv/bin/python3 bot.py
Restart=always
RestartSec=10
EnvironmentFile=/opt/wdtt-bot/.env

[Install]
WantedBy=multi-user.target
```

---

## 15. Зависимости

```
python-telegram-bot>=20.0
python-dotenv>=1.0.0
```

---

## 16. TODO

- [ ] Базовый бот с /start, /help
- [ ] Диалог /new (срок → хэш → пароль)
- [ ] Список /list с inline-кнопками
- [ ] Инструкция /info с wdtt:// ссылкой
- [ ] Удаление /delete с подтверждением
- [ ] Деактивация /activate, /deactivate
- [ ] Статистика /stats
- [ ] Рассылка /broadcast
- [ ] Systemd сервис
- [ ] Деплой на prod

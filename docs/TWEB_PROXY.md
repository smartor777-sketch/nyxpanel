# WEB Proxy — Панель управления + Telegram-бот

Веб-панель и Telegram-бот для управления прокси-профилями **tproxy-server** (HTTP/HTTPS/WebSocket транспорт).

---

## Архитектура

```
┌──────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Веб-панель  │────▶│ profiles.json│◀────│  tproxy-server  │
│  (Flask)     │     │ tg_mappings  │     │  (Go binary)    │
└──────────────┘     └──────────────┘     └─────────────────┘
                            ▲
┌──────────────┐           │
│ Telegram бот │───────────┘
│  (aiogram)   │
└──────────────┘
```

**Ключевой момент:** `tproxy-server` не принимает посторонние поля в `profiles.json`. Поэтому привязки `telegram_user` хранятся отдельно в `/etc/tproxy-server/tg_mappings.json`.

---

## Веб-панель

URL: `https://panel.kuban-forum.ru/self/tproxy`

### Функции

- **Список профилей** — имя, backend, режим, кнопки копирования, Telegram-привязка
- **Добавление профиля** — автоматически генерируется `secret`, выбирается следующий свободный порт
- **Удаление профиля** — с подтверждением
- **Telegram-привязка** — поле `Telegram` в таблице для каждого профиля (ID или `@username`)
- **Копирование** — секрет, ссылка подключения, JSON-конфиг — всё в один клик

### Данные

| Файл | Описание |
|------|----------|
| `/etc/tproxy-server/profiles.json` | Профили для tproxy-server (только стандартные поля) |
| `/etc/tproxy-server/tg_mappings.json` | Привязки `name → telegram_user` |
| `/etc/tproxy-server/config.json` | Конфигурация tproxy-server (`public_hostname` и др.) |

### Структура `profiles.json`

```json
{
  "profiles": [
    {
      "name": "default",
      "secret": "2b13b941f042b5e991d0685cfb81c96c",
      "backend": "127.0.0.1:2398",
      "carrier_mode": "https"
    }
  ]
}
```

### Структура `tg_mappings.json`

```json
{
  "default": "1139341866",
  "fanwriter": "@fanwriter"
}
```

---

## Telegram-бот

Бот: `@tgwpnewbot`  
Команды: `/start`, `/profiles`, `/config`, `/help`

### Логика доступа

| Тип пользователя | Что видит |
|-------------------|-----------|
| **Админ** (из `TG_PROXY_BOT_ADMINS`) | Все профили без фильтрации |
| **Обычный пользователь** | Только профили, привязанные к его Telegram ID или `@username` |
| **Незнакомый пользователь** | Сообщение: «Обратитесь к Администратору» |

### Привязка

Профиль привязывается к пользователю через поле `Telegram` в веб-панели.
Один пользователь может иметь **несколько профилей**.

### Пагинация

Если профилей больше 5 — они разбиваются по страницам с кнопками ← →.

### Deep link для подключения

```
https://t.me/webproxy?server={hostname}&secret={secret}
```

> ⚠️ Не путать с `t.me/proxy` — это для MTPROTO, а не для WEB-прокси.

---

## Деплой

### Серверные файлы

| Файл | Назначение |
|------|------------|
| `server/tproxy/tproxy-server.service` | Systemd-юнит tproxy-server |
| `server/tproxy/tg-proxy-bot.service` | Systemd-юнит Telegram-бота |
| `server/tproxy/bot.env.example` | Шаблон переменных окружения для бота |
| `server/tproxy/deploy-bot.sh` | Скрипт деплоя бота |
| `server/tproxy/deploy-tproxy.sh` | Скрипт деплоя tproxy-server |
| `server/tproxy/firewall.nft` | Правила nftables для блокировки портов |
| `server/tproxy/config.json` | Конфигурация tproxy-server |

### Установка

```bash
# 1. Установить tproxy-server
bash deploy-tproxy.sh

# 2. Скопировать конфиг
cp config.json /etc/tproxy-server/config.json

# 3. Настроить переменные для бота
cp bot.env.example bot.env
# Заполнить TG_PROXY_BOT_TOKEN, TG_PROXY_BOT_ADMINS

# 4. Деплой бота
bash deploy-bot.sh
```

### Переменные окружения бота

| Переменная | Описание |
|------------|----------|
| `TG_PROXY_BOT_TOKEN` | Токен Telegram-бота |
| `TG_PROXY_BOT_ADMINS` | ID админов через запятую |
| `TPROXY_PROFILES_PATH` | Путь к `profiles.json` |
| `TPROXY_CONFIG_PATH` | Путь к `config.json` |
| `TPROXY_TG_MAPPINGS_PATH` | Путь к `tg_mappings.json` |

---

## Поддерживаемые режимы транспорта

| Режим | carrier_mode |
|-------|-------------|
| HTTPS | `https` |
| WebSocket | `websocket-lanes` |

---

## Требования

- Python 3.10+
- `aiogram` 3.x
- `tproxy-server` (Go-бинарник)
- Systemd
- nftables

# Panel

Flask-панель управления. Исходники: `panel/proxy-panel.zip`.

## Текущее состояние

Базовый Flask + Caddy reverse proxy.
- URL: `https://76t05pyu.ikill.baby:8443/panel/`
- Логин: `admin` / `admin123`
- Базовая аутентификация через Caddy

## Roadmap (docs/panel-roadmap.md)

| Этап | Описание |
|------|----------|
| 1 | Traffic tracking + expiry (SQLite, cron collectors, Chart.js) |
| 2 | REST API (Flask blueprint `/api/v1/`) |
| 3 | Subscription links (V2Ray, Sing-box, Clash, Hiddify) |
| 4 | Telegram bot (python-telegram-bot v21+) |
| 5 | User-side self-service dashboard | ✅ Traffic chart (Today/Week/Month/All), expiry/limit, admin role with user list |
| 6 | Device/IP connection limits |
| 7 | User plan templates |
| 8 | Bulk operations |
| 9 | Backup & restore |
| 10 | Audit logging |
| 11 | **Log-agent для Caddy/Mieru** — демон агрегирует трафик из логов без парсинга всего объёма |

## Правила

- Flask + SQLite (не используем внешние БД)
- Caddy как reverse proxy с basicauth
- Панель доступна только через 8443
- REST API только для авторизованных админов

# NYX Panel — поэтапное расширение веб-панели управления прокси

> **Текущее состояние:** базовая панель (Flask + Caddy) — добавление/удаление пользователей,
> протоколов, скачивание конфигов и QR-кодов. Управление через `proxy_manager.sh`.
>
> **Цель:** превратить NYX Panel в полноценную систему управления с учётом трафика,
> лимитами, подписками, Telegram-ботом и REST API.

---

## Общий план (3 фазы)

| Фаза | Что делаем | Результат |
|------|-----------|-----------|
| **Фаза 1 — Разработка на стенде** | Заказать новый сервер, установить через pxy (как prod). Разработать панель, olcbox, olcRTC не трогая prod | Работающая панель на стенде со всеми протоколами |
| **Фаза 2 — Миграция на prod** | Перенести готовую панель на `76t05pyu.ikill.baby`. Подключиться к существующим сервисам и пользователям | Prod работает через новую панель. Стенд остаётся для дальнейшей разработки |
| **Фаза 3 — Установка с нуля (Catalogue + Installer)** | Панель сама умеет ставить протоколы на голый Linux через SSH. pxy становится не обязателен — панель полностью самодостаточна | Панель = инсталлятор + менеджер в одном процессе |

Этапы 0-10 ниже детализируют функциональность внутри фаз.

### О названии

Название **NYX** (греч. Нюкс — богиня ночи) свободно: нет пересечений на npm, PyPI
и GitHub в контексте прокси-панелей.

**GitHub:** https://github.com/smartor777-sketch/nyxpanel

---

## Эталонные проекты

| Проект | Ссылка | Специализация | Звёзд | Заимствуем |
|--------|--------|---------------|-------|------------|
| **3X-UI** | https://github.com/MHSanaei/3x-ui | Xray (VLESS, VMess, Trojan, SS, WG, Hy2, REALITY) | 42K | Per‑client traffic, expiry, IP limit, subscriptions, Telegram-бот, bulk-операции |
| **Marzban** | https://github.com/Gozargah/Marzban | Xray (VLESS, VMess, Trojan, SS, REALITY) | 20K+ | REST API, multi‑admin, user templates, subscription‑based outbounds |
| **Blitz** | https://github.com/ReturnFI/Blitz | Hysteria2 | — | WARP integration, masquerade, geo‑files, sub‑links |
| **CELERITY** | https://github.com/clickdevtech/celerity-panel | Hysteria2 + Xray VLESS | — | Server groups, load balancing, ACL, webhooks, 2FA |
| **h-ui** | https://github.com/jonssonyan/h-ui | Hysteria2 | — | User online status, force logoff, port hopping, import/export users |
| **NexusPanel** | https://nexuspanel.store/ | Xray + Hysteria2 (коммерческая) | — | Реальный IP‑лимит через парсинг access.log, Grafana‑стиль аналитики |
| **PPanel** | https://ppanel.dev/ | Мультипротокольная | — | User groups (VIP/Regular/Trial), balance/credit, churn prediction |
| **Flirexa** | https://flirexa.biz/ | WG, AWG, Hy2, TUIC (коммерческая) | — | Client self‑service portal, crypto payments, promo codes, support tickets |

---

## Этап 1 — трафик и срок действия (базовая аналитика)

**Откуда:** 3X-UI, Marzban, h-ui

### Что делаем

1. **SQLite‑база `panel.db`** с таблицами:
   - `users` — id, username, password_hash, created_at
   - `user_services` — user_id, protocol, config_data, traffic_limit_bytes, traffic_used_bytes, expire_at, status (active/disabled/expired/limited)
   - `traffic_log` — user_service_id, rx_bytes, tx_bytes, recorded_at
2. **Сбор статистики:** cron-скрипт раз в 5 минут парсит логи/статусы:
   - Xray: `access.log` → rx/tx per user
   - Hysteria2: `api traffic` из memory
   - olcRTC: RPC к каждому процессу
   - AWG: `wg show` transfer
3. **Отображение в панели:**
   - Таблица юзеров: колонки `Использовано / Лимит`, `Осталось дней`
   - Прогресс-бар (зелёный → жёлтый → красный при >80%)
   - График трафика за 24ч / 7д / 30д (Chart.js или Google Charts)
4. **Auto‑disable:** при превышении лимита или истечении срока — протоколы юзера автоматически отключаются
5. **Поля при создании:** `data_limit_gb`, `expire_days`

### Файлы

- `/opt/proxy-panel/panel.db` — SQLite
- `/opt/proxy-panel/traffic_collector.py` — сбор метрик
- `/opt/proxy-panel/app.py` — новые роуты + поля в формах
- `/opt/proxy-panel/templates/index.html` — колонки трафика и срока
- `/etc/cron.d/proxy-panel-traffic` — вызов collector каждые 5 минут
- `/root/proxy_manager.sh` — новые параметры `--data-limit`, `--expire`

---

## Этап 2 — REST API

**Откуда:** Marzban (Swagger-документация), 3X-UI (/panel/api/)

### Что делаем

Flask blueprint `/api/v1/` с авторизацией по API-ключу:

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/api/v1/users` | Список юзеров (с фильтрами: status, protocol) |
| POST | `/api/v1/users` | Создать юзера |
| GET | `/api/v1/users/<id>` | Инфо + трафик |
| PUT | `/api/v1/users/<id>` | Обновить лимиты/статус |
| DELETE | `/api/v1/users/<id>` | Удалить |
| POST | `/api/v1/users/<id>/reset-traffic` | Сбросить трафик |
| GET | `/api/v1/users/<id>/config/<protocol>` | Скачать конфиг |
| GET | `/api/v1/stats` | Общая статистика |
| GET | `/api/v1/health` | Статус сервера |

**OpenAPI/Swagger:** встроенная документация по `GET /api/v1/docs`

---

## Этап 3 — подписки (subscription links)

**Откуда:** 3X-UI, Marzban, Blitz

### Что делаем

Для каждого юзера генерируем **subscription token**.
По ссылке `https://76t05pyu.ikill.baby:8443/panel/sub/<token>` возвращаем конфиг
в формате, который понимают клиенты:

- **V2Ray / Sing-box** — JSON или YAML с конфигами всех протоколов юзера
- **Clash / ClashMeta** — YAML под их формат (`proxies:`, `proxy-groups:`)
- **Hiddify** — нативный XML

При обновлении конфига на сервере — клиент автоматом забирает новую версию
(клиенты сами делают subscription‑refresh).

### URL format

```
https://76t05pyu.ikill.baby:8443/panel/sub/<token>
https://76t05pyu.ikill.baby:8443/panel/sub/<token>/clash
https://76t05pyu.ikill.baby:8443/panel/sub/<token>/singbox
```

---

## Этап 4 — Telegram-бот

**Откуда:** 3X-UI, Marzban, Blitz, h-ui

### Что делаем

Python-бот (`python-telegram-bot v21+`) как отдельный сервис `proxy-bot.service`.

**Команды:**

| Команда | Описание |
|---------|----------|
| `/start` | Приветствие, проверка авторизации |
| `/create <user> <protocols> [limit_gb] [days]` | Создать юзера |
| `/delete <user>` | Удалить |
| `/list` | Список юзеров + трафик |
| `/traffic <user>` | Сколько накачал юзер |
| `/disable <user>` / `/enable <user>` | Вкл/выкл юзера |
| `/status` | Статус сервера: CPU, RAM, uptime, общий трафик |
| `/reset <user>` | Сбросить трафик в 0 |
| `/config <user> <protocol>` | Скинуть конфиг в чат |

**Уведомления (автоматические):**
- Юзер превысил 90% лимита → админ в Telegram
- Юзер истёк → админ
- Панель перезагружена → админ

**Авторизация:** белый список Telegram user_id в panel.db.

---

## Этап 5 — User‑side dashboard (самообслуживание)

**Откуда:** PPanel, Flirexa, NexusPanel

### Что делаем

Отдельная Flask-страница `/panel/profile/<token>` для конечного пользователя
(без пароля — доступ по sub-token):

```
╔══════════════════════════════════╗
║  Ваш профиль                     ║
║                                  ║
║  Пользователь: Merlin            ║
║  Статус: ● Активен               ║
║                                  ║
║  Трафик:   ████████░░ 7.2 / 10 G ║
║  Осталось: 23 дня                ║
║  Подключено устройств: 2 из 3    ║
║                                  ║
║  [Скачать конфиги]               ║
║  [QR-коды]                       ║
║  [Проверить соединение]          ║
╚══════════════════════════════════╝
```

Пользователь может:
- Скачать конфиги / QR-коды
- Сменить пароль (если протоколы с userpass)
- Посмотреть историю трафика
- Увидеть, какие IP сейчас подключены

---

## Этап 6 — Лимит устройств (IP/connection limit)

**Откуда:** 3X-UI, NexusPanel

### Что делаем

Лимит одновременных подключений для каждого юзера.

**Для Xray:**
- Парсим `access.log`: `user@email — dest — ip`
- Считаем уникальные IP за window (10 минут)
- Если больше лимита — client.disabled через REST, возвращаем через 10 минут

**Для olcRTC:**
- Каждый Session знает `claims.user`
- Ведём счётчик активных сессий на юзера
- При превышении — не даём открыть SOCKS5 (отвечаем ошибкой)

**Для Hysteria2:**
- Используем `maxClients` или парсим лог

Поле при создании юзера: `device_limit` (по умолчанию 3).

---

## Этап 7 — Шаблоны планов (user templates)

**Откуда:** Marzban (user templates), PPanel (user groups)

### Что делаем

В админке создаётся шаблон:

```json
{
  "name": "Basic",
  "traffic_limit_gb": 10,
  "expire_days": 30,
  "device_limit": 2,
  "protocols": ["vless", "hy2"],
  "speed_limit_mbps": 50,
  "price": 0
}
```

При создании юзера: выбрать шаблон → все поля заполняются автоматом.
Можно перезаписать отдельные поля.

Шаблоны хранятся в `/opt/proxy-panel/templates.json`.

---

## Этап 8 — Bulk-операции

**Откуда:** 3X-UI (bulk-edit), NexusPanel

### Что делаем

В таблице пользователей — чекбоксы слева и панель действий:

```
[☐] [☑] [☑] [☐] [☑]  ← чекбоксы
                        ╔══════════════════╗
                        ║ Удалить выбранные ║
                        ║ Продлить на 30 дн ║
                        ║ Сбросить трафик   ║
                        ║ Отключить / Вкл   ║
                        ║ Скачать конфиги   ║
                        ╚══════════════════╝
```

---

## Этап 9 — Бэкап и восстановление

**Откуда:** 3X-UI (экспорт/импорт .db), CELERITY (S3 backups)

### Что делаем

- Кнопка "Backup" в панели → дамп panel.db + YAML-конфиги протоколов → zip
- Автоматический ежедневный бэкап через cron в `/root/panel-backups/`
- Кнопка "Restore" — загрузить zip, перезаписать базу, перезагрузить протоколы

```bash
# ручной бэкап
curl -X POST -H "Authorization: Bearer <admin-key>" \
  https://76t05pyu.ikill.baby:8443/api/v1/backup \
  -o panel-backup-$(date +%Y%m%d).zip
```

---

## Этап 10 — Аудит и логи

**Откуда:** NexusPanel (audit log), 3X-UI (login history)

### Что делаем

Таблица `audit_log` в panel.db:

| time | admin | action | target | detail |
|------|-------|--------|--------|--------|
| 2026-07-18 12:00 | admin | create_user | Merlin | hy2, vless, 10GB, 30d |
| 2026-07-18 12:05 | admin | delete_user | Katya | — |
| 2026-07-18 14:00 | Merlin | config_download | vless | from /profile |
| 2026-07-18 14:01 | system | auto_disable | Merlin | traffic_limit exceeded |

---

---

## Этап 0 — Установка компонентов (Catalogue + Installer)

**Откуда:** pxy, модульная архитектура (`ARCHITECTURE/modules.md`)

### Что делаем

Панель умеет **устанавливать, обновлять и удалять** любой протокол через UI — как на локальном сервере, так и на удалённом по SSH.

### Catalogue — манифест компонентов

```json
{
  "xray": {
    "repo": "XTLS/Xray-core",
    "binary": "xray",
    "config": "/usr/local/etc/xray/config.json",
    "service": "xray.service",
    "default_config": "templates/xray_vless_reality.json",
    "deps": ["jq"],
    "check": "xray version"
  },
  "hy2": {
    "repo": "apernet/hysteria",
    "binary": "hysteria-server",
    "config": "/etc/hysteria/config.yaml",
    "service": "hysteria-server.service",
    "default_config": "templates/hy2_userpass.yaml",
    "check": "hysteria server --version"
  },
  "caddy": {
    "repo": "caddyserver/caddy",
    "binary": "caddy",
    "config": "/etc/caddy/Caddyfile",
    "service": "caddy.service",
    "default_config": "templates/caddy_panel.json",
    "deps": ["xcaddy"],
    "check": "caddy version"
  },
  "awg": {
    "repo": "amnezia-vpn/amneziawg-tools",
    "binary": "awg",
    "config": "/etc/amnezia/amneziawg/awg0.conf",
    "service": "awg-quick@awg0.service",
    "deps": ["qrencode"],
    "check": "awg --version"
  },
  "mieru": {
    "repo": "mieru/install-mita.sh",
    "binary": "mita",
    "config": "/etc/mita/server.json",
    "service": "mita.service",
    "check": "mita --version"
  },
  "olcrtc": {
    "binary": "olcrtc",
    "config": "/root/.config/olcrtc/server.yaml",
    "service": "olcrtc.service",
    "users_file": "/etc/olcrtc/users.json",
    "check": "olcrtc version"
  }
}
```

Catalogue хранится в панели и может обновляться (проверка новых версий на GitHub).

### Установка

```
POST /api/v1/install/xray
{
  "target": "local",
  "version": "latest"
}
```

- **local** — панель скачивает бинарник, раскладывает конфиги, создаёт systemd unit, запускает
- **remote** — панель использует SSH (paramiko) для установки на удалённый сервер

```
POST /api/v1/install/xray
{
  "target": "remote",
  "host": "10.0.0.2",
  "port": 22,
  "auth": {
    "method": "password",
    "password": "***"
  },
  "version": "1.8.4"
}
```

**SSH используется только для установки/обновления/удаления.** После установки Protocol Agent сам регистрируется в Service Registry, и всё дальнейшее управление идёт через REST API без SSH.

### Обновление

```
POST /api/v1/update/xray
```

Панель сверяет текущую версию с catalogue, если есть новая — скачивает, заменяет бинарник, перезапускает сервис.

### Удаление

```
POST /api/v1/uninstall/xray
```

- Останавливает сервис
- Удаляет systemd unit
- Чистит конфиги (опционально)
- Отписывает Protocol Agent из Registry

### UI

```
┌─────────────────────────────────────────────┐
│  Управление компонентами                     │
│                                             │
│  ┌───┬──────────┬────────┬────────┬──────┐  │
│  │ # │ Компонент│ Статус │ Версия │ Действия│
│  ├───┼──────────┼────────┼────────┼──────┤  │
│  │ 1 │ Xray     │ ● active│ 1.8.4 │ [🔄] [🗑]│
│  │ 2 │ Hy2      │ ● active│ 0.6.3 │ [🔄] [🗑]│
│  │ 3 │ Caddy    │ ● active│ 2.9.1 │ [🔄] [🗑]│
│  │ 4 │ AWG      │ ○ absent│  —    │ [➕]   │
│  │ 5 │ Mieru    │ ○ absent│  —    │ [➕]   │
│  │ 6 │ olcRTC   │ ● active│ 0.5.0 │ [🔄] [🗑]│
│  └───┴──────────┴────────┴────────┴──────┘  │
│                                             │
│  [➕ Установить выбранные]                  │
│                                             │
│  Сервер: local / 10.0.0.2 (remote)         │
│  [Добавить сервер ➕]                       │
└─────────────────────────────────────────────┘
```

### Управление серверами

Панель хранит список серверов, их SSH-доступ и какие протоколы на них установлены:

```json
{
  "servers": [
    {
      "id": "ams-01",
      "host": "10.0.0.1",
      "label": "Amsterdam #1",
      "auth": { "method": "key", "key_file": "/root/.ssh/id_panel" },
      "protocols": ["xray", "hy2", "caddy"],
      "status": "online"
    },
    {
      "id": "fra-01",
      "host": "10.0.0.2",
      "label": "Frankfurt #1",
      "auth": { "method": "password", "password": "***" },
      "protocols": ["caddy"],
      "status": "online"
    }
  ]
}
```

### Безопасность SSH

- Пароли хранятся зашифрованными в SQLite (AES-GCM с мастер-ключом из переменной окружения)
- SSH-ключи хранятся в файловой системе, доступной только panel service
- После установки SSH-доступ можно отозвать — Protocol Agent продолжит работать через REST

### Что это даёт

- **Установка pxy больше не нужна** — панель сама может поставить себе любой протокол
- **Удалённые серверы** — один дашборд для серверов в разных локациях
- **Автообновление** — кнопка обновления для любого компонента
- **Изоляция** — можно иметь 10 серверов Xray в разных регионах и управлять из одной панели
- **Никакой vendor lock** — catalogue — это просто JSON, можно править под свои сборки

---

## График (приоритеты)

```
Сейчас    Этап 0 — установка компонентов (Catalogue + Installer)
  ↓
Через 2н  Этап 1 — трафик + expiry
  ↓
Через 4н  Этап 2 — REST API
  ↓
Через 6н  Этап 3 — подписки
  ↓
Через 8н  Этап 4 — Telegram-бот
  ↓
Через 3м  Этап 5 — user dashboard
  ↓
Через 4м  Этапы 6–10 (по мере необходимости)
```

---

## Как не сломать существующее

1. Все изменения — **аддитивные**: старые поля в формах остаются, добавляются новые
2. `proxy_manager.sh` продолжает работать — новые параметры опциональны
3. `panel.db` создаётся первой же миграцией, `app.py` проверяет её наличие при старте
4. Subscription-ссылки не мешают прямому скачиванию конфигов
5. API-ключи не отменяют basicauth на Caddy

# Модульная архитектура NYX Panel

> Декомпозиция монолита в независимые модули с единым API.

## Проблема

Текущая архитектура — монолит на одном сервере. `proxy_manager.sh` управляет всеми протоколами локально, панель — тонкая HTML-обёртка. Это не позволяет:

- Разносить протоколы по разным серверам
- Добавлять новый протокол без правки общего скрипта
- Масштабировать нагрузку
- Изолировать сбои (падение Caddy не должно влиять на Xray)

## Архитектура

```
┌─────────────────────────────────────────────────────────────────┐
│                         Panel Core                              │
│  Flask + SQLite (users, traffic, config cache)                  │
│  REST API: /api/v1/users, /api/v1/traffic, /api/v1/services    │
│  UI: admin dashboard, user self-service, stats                  │
└────────────────────┬────────────────────────────────────────────┘
                     │ HTTP
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Service Registry                           │
│  Знает где какой агент живёт                                    │
│  Хранит: {protocol: {server, port, api_key, status}}           │
│  API: /register, /discover, /health                             │
└────────────────────┬────────────────────────────────────────────┘
          ┌──────────┼──────────┐              ┌──────────────────┐
          ▼          ▼          ▼              │                  │
┌─────────────────┐  ┌─────────────────┐       │  Traffic         │
│ Protocol Agent  │  │ Protocol Agent  │       │  Collector       │
│ (Xray)          │  │ (Hy2)           │  ...   │  ─────────────  │
│ ─────────────── │  │ ─────────────── │       │  pull metrics    │
│ /add_user       │  │ /add_user       │       │  from Xray/Hy2/  │
│ /del_user       │  │ /del_user       │       │  nftables        │
│ /list_users     │  │ /list_users     │       │  push → Panel    │
│ /status         │  │ /status         │       │  Core /api/v1/   │
│ /stats          │  │ /stats          │       │  traffic         │
│ REST API        │  │ REST API        │       └──────────────────┘
└─────────────────┘  └─────────────────┘
        Сервер A           Сервер B
```

## Компоненты

### Panel Core

Единая точка входа для администратора.

| Функция | Описание |
|---------|----------|
| `Flask UI` | Dashboard, таблица пользователей, графики трафика |
| `REST API /api/v1/` | CRUD пользователей, запрос статистики, управление подписками |
| `SQLite` | Пользователи, трафик (daily + per-user), истечение подписок, audit log |
| `Auth` | Caddy basicauth + JWT для API (опционально) |

**Не знает** о протоколах, серверах, конфигах. Вся коммуникация — через Service Registry.

### Service Registry

Единственное место, где хранится топология.

```
// Структура записи
{
  "protocol": "xray",
  "instance": "ams-01",
  "host": "10.0.0.1",
  "port": 9001,
  "api_key": "sk-...",
  "status": "online",
  "version": "1.0.0",
  "registered_at": "2026-07-18T10:00:00Z"
}
```

**API:**
| Метод | Путь | Описание |
|-------|------|----------|
| `POST` | `/register` | Агент регистрирует себя |
| `GET` | `/discover?protocol=xray` | Получить список инстансов протокола |
| `GET` | `/discover/{id}` | Получить конкретный инстанс |
| `GET` | `/health` | Статус всех агентов |
| `DELETE` | `/unregister/{id}` | Удалить агента |

Panel Core не кеширует registry — каждый запрос проходит через него. Это гарантирует актуальность топологии.

### Protocol Agent

Каждый протокол имеет свой агент — отдельный процесс (Python/Go/Bash), который запущен на сервере с этим протоколом и реализует единый REST API.

**Обязательный API (реализует каждый агент):**

| Метод | Путь | Описание |
|-------|------|----------|
| `POST` | `/add_user` | Создать пользователя на протоколе |
| `POST` | `/del_user` | Удалить пользователя |
| `GET` | `/list_users` | Список пользователей |
| `GET` | `/status` | Статус протокола (online/offline, версия, uptime) |
| `GET` | `/stats/{user}` | Статистика пользователя (traffic in/out, sessions) |
| `GET` | `/config/{user}` | Сгенерировать клиентский конфиг |

**Опциональный API:**
| Метод | Путь | Описание |
|-------|------|----------|
| `POST` | `/restart` | Перезапустить сервис |
| `POST` | `/apply_config` | Применить новый конфиг |
| `GET` | `/health` | Проверка здоровья |

**Агент НЕ зависит** от Panel Core или других агентов. Его можно запустить, остановить, переместить — он самодостаточен.

### Traffic Collector

Опциональный компонент, собирающий метрики.

```
Схема работы:
  Collector (cron / systemd timer)
       │
       ├── Xray → API /stats (gRPC или REST)
       ├── Hy2  → API /traffic
       ├── nftables → iptables counters
       │
       ▼
  POST Panel Core /api/v1/traffic
       │
       ▼
  SQLite (traffic_log)
```

Позволяет Panel Core быть stateless относительно сбора метрик — Collector берёт на себя агрегацию.

## Сценарии

### 1. Всё на одном сервере (текущий)

```
Один сервер: Panel Core + Registry + Agent Xray + Agent Hy2 + Agent Caddy + Collector
```

Проще деплоить, все модули на localhost. Registry всё равно нужен — он даёт единый API даже при локальной архитектуре.

### 2. NaiveProxy на отдельном сервере

```
Сервер A (основной):
  Panel Core + Registry + Agent Xray + Agent Hy2 + Agent AWG

Сервер B (Caddy/Naive):
  Agent Caddy → POST /register в Registry → Panel видит его
```

Панель в списке протоколов пользователя показывает NaiveProxy как активный, хотя физически он на другом сервере. Всё управление — через Agent Caddy на сервере B.

### 3. По протоколу на сервер

```
Сервер A: Agent Xray
Сервер B: Agent Hy2
Сервер C: Agent Caddy
Сервер D: Agent AWG
Сервер E: Agent Mieru
Сервер F: Agent olcRTC
Сервер G: Panel Core + Registry
```

Каждый агент живёт рядом со своим сервисом. Registry — единственная точка связности.

### 4. Несколько инстансов одного протокола

```
Registry возвращает:
  [
    {protocol: "xray", instance: "eu-01", ...},
    {protocol: "xray", instance: "us-01", ...},
    {protocol: "xray", instance: "asia-01", ...},
  ]

Panel Core: при add_user выбирает наименее загруженный инстанс.
           Или пользователь выбирает регион сам.
```

## Реализация

### Protocol Agent (Python — быстрый старт)

```python
# protocol_agent_xray/main.py
from flask import Flask, request, jsonify
import subprocess, json

app = Flask(__name__)

@app.post("/add_user")
def add_user():
    username = request.json["username"]
    # ... сгенерить UUID, добавить в xray config, systemctl restart xray
    return jsonify({"status": "ok", "uuid": uuid, "uri": uri})

@app.get("/list_users")
def list_users():
    # ... прочитать users.json
    return jsonify({"users": users})

# Единый интерфейс — любой протокол можно добавить
```

```python
# protocol_agent_caddy/main.py
# Те же методы, но логика под капотом — правка Caddyfile + reload

@app.post("/add_user")
def add_user():
    username = request.json["username"]
    password = secrets.token_urlsafe(16)
    # ... добавить basic_auth в Caddyfile, systemctl reload caddy
```

### Service Registry (самый лёгкий — тоже SQLite + Flask)

```python
registry = {}  # или SQLite

@app.post("/register")
def register():
    data = request.json
    registry[data["protocol"]] = data
    return jsonify({"status": "registered"})

@app.get("/discover")
def discover():
    protocol = request.args.get("protocol")
    instances = [v for v in registry.values() if v["protocol"] == protocol]
    return jsonify(instances)

@app.get("/health")
def health():
    results = {}
    for id_, agent in registry.items():
        try:
            r = requests.get(f"http://{agent['host']}:{agent['port']}/health", timeout=2)
            results[id_] = r.json()
        except:
            results[id_] = {"status": "unreachable"}
    return jsonify(results)
```

## pxy — one-click installer

[pxy](https://github.com/openlibrecommunity/pxy) — это Wails desktop GUI (Go + TypeScript), который через SSH устанавливает все 6 протоколов на сервер одной кнопкой:

```
Пользователь запускает pxy на своём ПК
       │
       ├── SSH root@server
       ├── Устанавливает Xray + Hy2 + AWG + Caddy + Mieru + olcRTC
       ├── Настраивает free домен (pxy.zarazaex.xyz DNS)
       └── Генерирует QR-коды/конфиги
```

**Важно:** pxy — это десктопный инсталлятор, а не серверный демон. Он НЕ является частью панели и НЕ нужен для её работы.

### Panel + pxy

Panel Core может опционально определять, что сервисы были установлены через pxy:

1. Проверять наличие маркер-файла (`/etc/pxy-installed`)
2. Или определять каждый протокол независимо (по наличию бинарника/конфига)
3. Registry может предзаполняться из `proxy_manager.sh` если он найден на сервере

### Panel без pxy (standalone)

Сервисы могут быть установлены вручную, через Ansible, Docker, или любой другой способ. Protocol Agent просто запускается рядом с каждым сервисом. Panel Core видит только то, что зарегистрировано в Service Registry — ей всё равно, как сервисы были установлены.

**Единственное требование:** Protocol Agent должен иметь те же права, что и `proxy_manager.sh` (root), чтобы управлять сервисами (systemctl restart, правка конфигов в `/etc/`).

## Миграция с текущей архитектуры

| Шаг | Что делаем |
|-----|-----------|
| 1 | Выделить Protocol Agent как отдельный класс (сейчас `proxy_manager.sh` — монолит) |
| 2 | Разбить `proxy_manager.sh` на модули: `lib_xray.sh`, `lib_hy2.sh`, `lib_caddy.sh`, `lib_awg.sh`, `lib_mieru.sh`, `lib_olcrtc.sh` |
| 3 | Завернуть каждый модуль в REST API (Python Flask / FastAPI) |
| 4 | Развернуть Service Registry (лёгкий Flask + SQLite) |
| 5 | Подключить Panel Core к Registry вместо прямых вызовов |
| 6 | Collector — отдельный cron/systemd unit |

Шаги 1-3 можно делать на том же сервере, в том же процессе. Разнесение по серверам — опционально.

## Стек технологий

| Компонент | Язык | Фреймворк | Хранение |
|-----------|------|-----------|----------|
| Panel Core | Python | Flask | SQLite |
| Service Registry | Python | Flask | SQLite |
| Protocol Agent | Python | Flask | — |
| Traffic Collector | Python | requests + cron | — |
| Protocol Agent (olcRTC) | Go | net/http | — |

## Что остаётся неизменным

- **SQLite** — Panel Core и Registry оба используют SQLite. Это корректно, так как они работают на одном сервере или Registry можно сделать единственной БД.
- **Caddy** — фронтенд-прокси для Panel Core, как сейчас.
- **`docs/SERVER_CONFIG.md`** — добавляем секцию с топологией (какие агенты на каких серверах).

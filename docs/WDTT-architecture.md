# WDTT — Архитектура и реализация

## 1. Обзор

**WDTT** (WireGuard over TURN Tunnel) — система создания защищённого VPN-туннеля поверх TURN/DTLS медиарелей VK. Трафик маскируется под аудио/видеозвонок VK, что позволяет обходить DPI и блокировки.

### Полная архитектура

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Prod сервер (87.120.186.100)                 │
│                                                                     │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────┐  │
│  │  Chromium        │    │  WDTT Docker     │    │  Systemd     │  │
│  │  (headless)      │    │  (wdtt-server)   │    │  (vk-eternal │  │
│  │                  │    │                  │    │   -call)      │  │
│  │  - cookies VK    │    │  - DTLS:56000    │    │              │  │
│  │  - звонок active │    │  - WG:56001      │    │  - рестарт   │  │
│  │  - рестарт 6ч    │    │  - NAT/MASQ      │    │    каждые 6ч │  │
│  └────────┬─────────┘    └────────┬─────────┘    └──────────────┘  │
│           │                       │                                 │
│           │   维持 звонок          │   принимает DTLS                │
│           │    (cookies)          │    (WRAP+WG)                    │
│           │                       │                                 │
└───────────┼───────────────────────┼─────────────────────────────────┘
            │                       │
            │ VK API                │ DTLS/WG
            │ (хэш звонка)         │ (трафик)
            │                       │
┌───────────┼───────────────────────┼─────────────────────────────────┐
│           │                       │                                 │
│  ┌────────▼─────────┐    ┌────────▼─────────┐                      │
│  │  Android клиент  │    │  VK TURN relay   │                      │
│  │  (WDTT app)      │    │  (calls.okcdn.ru)│                      │
│  │                  │    │                  │                      │
│  │  - хэш звонка    │───→│  - TURN creds    │                      │
│  │  - WRAP+RTP AEAD │    │  - username/pass │                      │
│  │  - WireGuard     │    │  - URLs          │                      │
│  └──────────────────┘    └──────────────────┘                      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Поток данных

```
1. Android клиент запрашивает TURN creds у VK API (используя хэш звонка)
2. VK API возвращает username/password/URLs
3. Android клиент подключается к WDTT серверу через DTLS (порт 56000)
4. Трафик шифруется WRAP (RTP AEAD) + WireGuard
5. WDTT сервер маршрутизирует трафик в интернет через NAT
```

### Роль каждого компонента

| Компонент | Роль | Важность |
|-----------|------|----------|
| **Chromium** | Поддерживает VK-звонок активным (хэш живой) | Критично для хэша |
| **WDTT сервер** | Принимает DTLS/WG, маршрутизирует трафик | Критично для трафика |
| **Android клиент** | Получает TURN creds, подключается к серверу | Критично для клиента |
| **VK TURN relay** | Предоставляет TURN creds (через хэш звонка) | Критично для creds |

```
Android/PC клиент → WRAP (RTP AEAD) → VK TURN/DTLS relay → WDTT сервер (VPS) → интернет
```

---

## 2. Серверная часть

### 2.1. Установленная конфигурация

| Компонент | Dev (2.26.51.8) | Prod (87.120.186.100) |
|-----------|----------------|----------------------|
| Docker | 29.7.2 | 29.7.2 |
| Docker Compose | v5.5.0 | v5.5.0 |
| WDTT Docker | ✅ | ✅ |
| Playwright | ✅ | ✅ |
| VK Eternal Call | ❌ | ✅ (systemd) |

**Prod сервер (87.120.186.100) — основной:**

| Компонент | Путь | Описание |
|-----------|------|----------|
| Docker | `/usr/bin/docker` | Docker 29.7.2 |
| Docker Compose | `/usr/bin/docker compose` | v5.5.0 |
| WDTT Docker | `/opt/proxy-turn-vk-android-server-fix/docker-wdtt/` | Контейнер с WDTT сервером |
| WDTT binary | `/usr/local/bin/wdtt-server` (внутри контейнера) | Go бинарник сервера |
| Конфиги | `/opt/proxy-turn-vk-android-server-fix/docker-wdtt/config/` | Ключи и пароли |
| Playwright | `/opt/pw-venv/` | Python venv для Playwright |
| VK Call Script | `/opt/vk-eternal-call.py` | Скрипт "вечного звонка" |
| VK Session | `/opt/vk-session/state.json` | Cookies VK |
| Systemd | `vk-eternal-call.service` | Автозапуск звонка |

### 2.2. Порты

| Порт | Протокол | Назначение |
|------|----------|------------|
| 56000 | UDP | DTLS — основной транспорт (обфусцированный) |
| 56001 | UDP | WireGuard — внутренний туннель |
| 22 | TCP | SSH (для управления) |

### 2.3. Docker контейнер

```yaml
# docker-compose.yml
services:
  wdtt:
    build: .
    container_name: wdtt-vpn
    restart: always
    network_mode: host          # Критично! Bridge не работает
    cap_add:
      - NET_ADMIN               # Для NAT/iptables
    devices:
      - /dev/net/tun:/dev/net/tun  # TUN интерфейс
    environment:
      - WDTT_DTLS_PORT=56000
      - WDTT_WG_PORT=56001
      - WDTT_CLIENT_CIDR=10.66.66.0/24
      - WDTT_ENABLE_TCPMSS=1
      - WDTT_ARGS=-password <пароль>
    volumes:
      - ./config:/etc/wdtt
```

**Важно:** `network_mode: host` обязателен — в bridge-режиме сервер падает с exit code 1.

### 2.4. Структура файлов

```
/opt/proxy-turn-vk-android-server-fix/docker-wdtt/
├── Dockerfile              # Debian slim + iptables + iproute2 + wdtt-server
├── docker-compose.yml      # Оркестрация
├── entrypoint.sh           # Инициализация NAT, запуск сервера
├── migrate.sh              # Миграция с systemd
├── .env                    # Переменные окружения (пароли, порты)
└── config/
    ├── wg-keys.dat         # 4 ключа WireGuard (private/public)
    └── passwords.json      # Пароли клиентов
```

### 2.5. Entrypoint (упрощённый)

```bash
#!/bin/sh
# 1. Настройка NAT/MASQUERADE
iptables -t nat -A POSTROUTING -s "$CLIENT_CIDR" -o "$WAN_IFACE" -j MASQUERADE

# 2. TCPMSS clamping (для стабильности)
iptables -t mangle -A FORWARD -s "$CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu

# 3. Запуск сервера
exec wdtt-server \
    -listen "0.0.0.0:${WDTT_DTLS_PORT}" \
    -wg-port "${WDTT_WG_PORT}" \
    -config-dir "/etc/wdtt" \
    ${WDTT_ARGS}
```

### 2.6. Серверные логи (пример)

```
[WG] Ключи загружены из /etc/wdtt/wg-keys.dat
[SYS] BBR включен ✓
[NAT] Внешний: ens3
[NAT] Режим: MASQUERADE iptables ✅
[WG] Запущен на порту 56001
[WRAP] password HKDF + RTP AEAD | keys: 1
[SERVER] Готов

# При подключении клиента:
[WRAP] OK: ключ выбран для 90.156.236.118:49809 (keys=1), PT=111
[WG] Новое устройство 793ac8e1ad3f7169 (IP: 10.66.66.2)
```

---

## 3. Клиентская часть

### 3.1. Поддерживаемые клиенты

| Клиент | Платформа | Капча | Ротация creds | Статус |
|--------|-----------|-------|---------------|--------|
| WDTT Android | Android | Авто (Go v2 + WebView) | Реактивная | ✅ Работает |
| PWDTT | Windows/Linux | Нет | Нет | ⚠️ Требует CSQTT |
| vk-turn-proxy client | Linux CLI | Нет | Нет | ⚠️ VK блокирует |
| CSQTT | Сервер | N/A | N/A | 🔨 Сборка сложная |

### 3.2. Android-клиент (WDTT)

**Исходники:** `app/src/main/assets/android-client/`

**Ключевые файлы Go-клиента:**

| Файл | Назначение |
|------|------------|
| `vk_auth.go` | Авторизация через VK (Identity + captcha) |
| `creds_vkcalls.go` | Получение TURN creds через VK Calls API |
| `session.go` | Управление DTLS-сессиями |
| `worker_group.go` | Пул воркеров (9 на группу), ротация creds |
| `dispatcher.go` | Маршрутизация пакетов |
| `obfs.go` | Обфускация (RTP AEAD) |
| `wrap.go` | WRAP-слой (шифрование поверх DTLS) |

### 3.3. Flow получения TURN creds (Android)

```
1. auth.getAnonymToken
   └→ Анонимный токен VK

2. messages.getCallPreview
   └→ user_id + secret

3. messages.getAnonymCallToken
   └→ OK anonymToken

4. auth.anonymLogin (calls.okcdn.ru)
   └→ session_key

5. vchat.joinConversationByLink
   └→ TURN creds: username, password, urls
```

### 3.4. Ротация токенов (реактивная модель)

**Как работает сейчас:**

```
Воркер отправляет пакет → получает ошибку
    ↓
Детект ошибки:
  - "invalid credential"
  - "stale nonce"
  - "allocation mismatch"
  - "error 508"
  - "quota"
    ↓
refreshCreds():
  - Кулдаун 15 сек между обновлениями
  - Повторный запрос TURN creds через VK API
  - Применение новых creds
    ↓
Повтор сессии с новыми creds
```

**Время даунтайма:** 5-15 секунд

**Проблемы реактивной модели:**
- VPN-туннель рвётся на 5-15 сек
- Сайты перезагружаются
- Стримы обрываются
- Voice/Video звонки прерываются

---

## 4. Улучшения клиента для ПК (PWDTT / vk-turn-proxy)

### 4.1. Проактивная ротация токенов

**Цель:** обновлять TURN creds за 1-2 минуты до истечения, обеспечив нулевой даунтайм.

**Архитектура:**

```
credential_manager.py / credential_manager.go
├── Таймер: обновление каждые ~7 минут (TTL = 9 мин)
├── Получение creds через VK API
├── Решение капчи через CapMonster/2Captcha
├── Горячая перезагрузка creds в клиент
└── Мониторинг состояния
```

**Реализация (Go):**

```go
type CredentialManager struct {
    mu          sync.RWMutex
    creds       *Credentials
    hash        string
    captchaKey  string  // API ключ CapMonster/2Captcha
    refreshTimer *time.Ticker
    onRefresh   func(*Credentials)  // callback для горячей перезагрузки
}

func (cm *CredentialManager) Start(ctx context.Context) {
    cm.refreshTimer = time.NewTicker(7 * time.Minute)
    go func() {
        for {
            select {
            case <-cm.refreshTimer.C:
                cm.refresh()
            case <-ctx.Done():
                return
            }
        }
    }()
}

func (cm *CredentialManager) refresh() {
    // 1. Получить новые creds
    // 2. Если капча → решить через CapMonster
    // 3. Применить новые creds
    // 4. Вызвать onRefresh callback
}
```

### 4.2. Интеграция CapMonster/2Captcha

**Flow:**

```
VK API возвращает captcha (error_code=14)
    ↓
Отправка изображения в CapMonster API
    ├→ https://api.capmonster.cloud/createTask
    └→ {taskKey: "VKSmartCaptcha", image: base64}
    ↓
Ожидание решения (5-30 сек)
    ├→ https://api.capmonster.cloud/getTaskResult
    └→ {solution: "abc123"}
    ↓
Отправка решения в VK API
    ↓
Получение TURN creds
```

**Пример интеграции (Python):**

```python
import requests

CAPMonster_API_KEY = "YOUR_KEY"

def solve_vk_captcha(image_base64: str, page_url: str) -> str:
    # Создать задачу
    task = {
        "type": "VKSmartCaptchaTask",
        "image": image_base64,
        "websiteURL": page_url,
    }
    resp = requests.post("https://api.capmonster.cloud/createTask", json={
        "clientKey": CAPMonster_API_KEY,
        "task": task,
    })
    task_id = resp.json()["taskId"]

    # Ждать решение
    while True:
        result = requests.post("https://api.capmonster.cloud/getTaskResult", json={
            "clientKey": CAPMonster_API_KEY,
            "taskId": task_id,
        }).json()
        if result["status"] == "ready":
            return result["solution"]["token"]
        time.sleep(2)
```

### 4.3. Headless браузер для "вечного звонка" (РЕАЛИЗОВАНО)

**Цель:** автоматически поддерживать VK-звонок на сервере 24/7.

**Стек:** Playwright (Python) + Chromium Headless Shell

**Сервер:** prod (87.120.186.100)

**Файлы:**

| Файл | Путь | Описание |
|------|------|----------|
| Скрипт | `/opt/vk-eternal-call.py` | Основной скрипт |
| Сервис | `/etc/systemd/system/vk-eternal-call.service` | Systemd unit |
| Сессия | `/opt/vk-session/state.json` | Cookies VK |
| ENV | `/opt/vk-call.env` | URL звонка |
| Логи | `/opt/vk-call.log` | Файл логов |

**Управление:**

```bash
# Статус
systemctl status vk-eternal-call

# Логи
journalctl -u vk-eternal-call -f
cat /opt/vk-call.log

# Стоп
systemctl stop vk-eternal-call

# Сменить звонок
echo 'VK_CALL_URL=https://vk.com/call/join/NOVYJ_HASH' > /opt/vk-call.env
systemctl restart vk-eternal-call
```

**Тайминги:**

| Параметр | Значение | Описание |
|----------|----------|----------|
| CHECK_INTERVAL | 60 сек | Проверка URL, сохранение cookies |
| RESTART_INTERVAL | 6 часов | Полный перезапуск Chromium |

**Поведение при перезапуске Chromium:**

```
Текущее состояние:
  Android клиент ──→ WireGuard туннель ──→ WDTT сервер (активно)

Перезапуск Chromium (каждые 6 часов):
  ┌─ 0-15 сек: Chromium закрывается
  │  ├─ Существующий WG туннель → работает (не разрывается)
  │  └─ Новые подключения → не могут получить TURN creds (хэш недоступен)
  │
  └─ 15+ сек: Chromium запускается с обновлёнными cookies
     ├─ Сессия восстанавливается
     └─ Хэш снова доступен

Влияние на пользователя:
  • Если туннель активен → не заметит (туннель не рвётся)
  • Если туннель断掉 во время рестарта → переподключение не удастся 10-15 сек
```

**Flow обновления cookies:**

```
Каждые 60 сек:
  1. Проверка текущего URL
  2. Если URL изменился (редирект) → переход обратно на звонок
  3. Сохранение cookies → state.json
  4. Sleep 60 сек

Каждые 6 часов:
  1. Закрытие Chromium
  2. Запуск нового Chromium с сохранёнными cookies
  3. Cookies могли обновиться (refresh VK)
  4. Переход на звонок
  5. Продолжение работы
```

### 4.4. Модификация Go-клиента для чтения внешних creds

**Цель:**.allow clients to read credentials from file/API instead of hardcoded VK auth.

**Изменения в `worker_group.go`:**

```go
// Добавить опцию внешнего источника creds
type CredSource interface {
    GetCreds(ctx context.Context) (*Credentials, error)
    RefreshCreds(ctx context.Context) error
}

// Файловый источник
type FileCredSource struct {
    Path string
    mu   sync.RWMutex
}

func (f *FileCredSource) GetCreds(ctx context.Context) (*Credentials, error) {
    f.mu.RLock()
    defer f.mu.RUnlock()
    // Чтение из JSON файла
}

// API источник
type APICredSource struct {
    Endpoint string
}
```

---

## 5. Возможные улучшения

### 5.1. Краткосрочные (легко реализуемы)

| Улучшение | Сложность | Описание |
|-----------|-----------|----------|
| Docker healthcheck | Низкая | Мониторинг состояния контейнера |
| Логирование в файл | Низкая | `docker logs` → файл + ротация |
| Автообновление пароля | Низкая | Скрипт для ротации пароля сервера |
| Firewall правила | Низкая | ufw/nftables вместо raw iptables |

### 5.2. Среднесрочные (требуют разработки)

| Улучшение | Сложность | Описание |
|-----------|-----------|----------|
| Telegram-бот управления | Средняя | Управление паролями, мониторинг |
| Web UI | Средняя | Дашборд с подключениями, логами |
| Мульти-сервер | Средняя | Балансировка между dev/prod |
| Метрики | Средняя | Prometheus + Grafana |

### 5.3. Долгосрочные (комплексная разработка)

| Улучшение | Сложность | Описание |
|-----------|-----------|----------|
| Проактивная ротация creds | Высокая | Интеграция CapMonster + горячая перезагрузка |
| ~~Headless VK звонок~~ | ~~Высокая~~ | ~~Playwright + автопереподключение~~ ✅ Реализовано |
| Свой WDTT клиент | Высокая | Go/Python клиент с CapMonster |
| Multi-hop routing | Высокая | Цепочка из нескольких серверов |

---

## 6. Деплой и управление

### 6.1. Установка на новый сервер

```bash
# 1. Установка Docker
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# 2. Клонирование репозитория
cd /opt
git clone --depth 1 --no-checkout https://github.com/michaillepichow/proxy-turn-vk-android-server-fix.git
cd proxy-turn-vk-android-server-fix
git sparse-checkout set docker-wdtt
git checkout
cd docker-wdtt

# 3. Настройка .env
cat > .env << EOF
WDTT_DTLS_PORT=56000
WDTT_WG_PORT=56001
WDTT_CLIENT_CIDR=10.66.66.0/24
WDTT_ENABLE_TCPMSS=1
WDTT_ARGS=-password ВАШ_ПАРОЛЬ
EOF

# 4. Запуск
docker compose up -d --build

# 5. Проверка
docker compose logs -f
```

### 6.2. Управление

```bash
# Логи
docker compose logs -f

# Перезапуск
docker compose restart

# Остановка
docker compose down

# Обновление
docker compose pull && docker compose up -d

# Проверка портов
ss -ulnp | grep -E '5600|56001'
```

### 6.3. Мониторинг

```bash
# Активные подключения
docker logs wdtt-vpn 2>&1 | grep "Новое устройство"

# Ошибки
docker logs wdtt-vpn 2>&1 | grep -i "error\|fail"

# Состояние контейнера
docker inspect wdtt-vpn --format='{{.State.Status}}'
```

---

## 7. Безопасность

### 7.1. Рекомендации

- Использовать уникальный пароль для каждого сервера
- Не публиковать пароль в открытом виде
- Регулярно обновлять Docker-образ
- Ограничивать SSH доступ (keys only)
- Настроить firewall (ufw/nftables)
- Мониторить логи на подозрительную активность

### 7.2. Пароли

| Тип | Назначение | Формат |
|-----|------------|--------|
| Server password | Главный пароль сервера | Строка, задаётся в .env |
| User passwords | Пароли пользователей | 16 символов, генерируются |

---

## 8. Известные ограничения

1. **VKcaptcha:** VK блокирует встроенные учётки — решение через CapMonster
2. **9-минутный TTL:** TURN creds истекают — нужна ротация
3. **Реактивная ротация:** Даунтайм 5-15 сек при обновлении
4. **Нет проактивной ротации:** Для desktop клиента требуется доработка
5. **~~Headless браузер~~:** ~~Требует cookies и авторизации в VK~~ ✅ Реализовано (prod: 87.120.186.100)
6. **Перезапуск Chromium:** 10-15 сек даунтайма каждые 6 часов (существующий туннель не рвётся)

---

## 9. Ссылки

- [Репозиторий WDTT](https://github.com/amurcanov/proxy-turn-vk-android)
- [Форк (серверная часть)](https://github.com/michaillepichow/proxy-turn-vk-android-server-fix)
- [Docker WDTT DOCKER.md](https://github.com/michaillepichow/proxy-turn-vk-android-server-fix/blob/main/docker-wdtt/DOCKER.md)
- [CapMonster API](https://capmonster.cloud/docs/api)
- [2Captcha API](https://2captcha.com/api)
- [Playwright Python](https://playwright.dev/python/)

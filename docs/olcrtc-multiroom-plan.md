# Multi‑Room Mode — план разработки

> **Цель:** один olcRTC-стек, работающий в трёх режимах, с обратной совместимостью и переключением без передеплоя всех клиентов.

---

## 1. Общая архитектура

### 1.1 Режимы работы сервера

Режим задаётся в `/root/.config/olcrtc/server.yaml` одним полем:

```yaml
mode: shared          # одна комната на всех (текущее поведение)
# mode: isolated      # процесс на пользователя
# mode: dynamic       # одна комната-диспетчер, сессии создаются на лету
```

Каждый режим использует **тот же claims-механизм** (`users.json`, user/pass).  
Разница — **как сервер выбирает Jitsi-комнату** и **сколько процессов** запущено.

### 1.2 Совместимость

| Клиент | shared | isolated | dynamic |
|--------|--------|----------|---------|
| claims (user+pass) | ✅ | ✅ | ✅ |
| UUID (без claims) | ✅ | ✅ через `default` | ✅ через `default` |

Любой клиент подключается к любому режиму без пересборки — комнату и способ аутентификации он **не выбирает**, сервер сам направляет.

---

## 2. Режим `shared` (уже работает)

Ничего не меняется.

```
Сервер → комната: meet.egovm.ru/pxy-76t05pyu.ikill.baby
Клиент → та же комната, claims или UUID
```

---

## 3. Режим `isolated` — процесс на пользователя

### 3.1 Принцип

При добавлении пользователя (`add_olcrtc_user`) запускается **отдельный** olcrtc-сервер с:
- своей Jitsi-комнатой `pxy-76t05pyu.ikill.baby-{username}`
- своим SOCKS5-портом (например, 11000 + user_id)
- своим systemd-юнитом `olcrtc@{username}.service`

### 3.2 Что нужно сделать

#### 3.2.1 Серверная часть (bash, systemd)

**A. Изменения в `proxy_manager.sh` — функция `add_olcrtc_user`:**

```
При добавлении olcRTC пользователю:
  1. Увеличить счётчик портов (PROXY_PORT_START=11000, инкремент)
  2. Записать в metadata пользователя: порт, комнату, claims
  3. Создать {user}_olcrtc.yaml для КЛИЕНТА (порт клиента всегда 1082, не меняется)
  4. Создать {user}_olcrtc_server.yaml для ИЗОЛИРОВАННОГО сервера:
       mode: srv
       auth:
         provider: jitsi
         users_file: /etc/olcrtc/users_{user}.json
       room:
         id: "https://meet.egovm.ru/pxy-76t05pyu.ikill.baby-{user}"
       crypto:
         key: SAME_MASTER_KEY
       socks:
         host: 127.0.0.1
         port: 11000+N     # уникальный порт
       data: /var/lib/olcrtc/{user}
       claims:
         user: {user}
         pass: {password}
  5. systemctl enable olcrtc@{user}
  6. systemctl start olcrtc@{user}
```

**B. Systemd template unit — `/etc/systemd/system/olcrtc@.service`:**

```ini
[Unit]
Description=olcRTC isolated server for %i
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/pj/olcrtc/build/olcrtc-linux-amd64 /root/proxy_users/%i/%i_olcrtc_server.yaml
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**C. Изменения в `del_user`:**

```
При удалении пользователя:
  1. systemctl stop olcrtc@{user}
  2. systemctl disable olcrtc@{user}
  3. rm -f /etc/olcrtc/users_{user}.json
  4. Очистить комнату (по желанию, Jitsi подчищает сам)
```

**D. Port allocator — `/root/.config/olcrtc/port_allocator.json`:**

```json
{
  "next_port": 11000,
  "allocated": {
    "Merlin": 11001,
    "test": 11002
  }
}
```

**E. Утилита `olcrtc-admin` (bash-скрипт или отдельная команда):**

```
olcrtc-admin mode                    # показать текущий режим
olcrtc-admin mode set isolated       # переключить режим
olcrtc-admin migrate shared-to-isolated  # перенести существующих юзеров
olcrtc-admin rooms                   # список всех комнат
olcrtc-admin port <user>             # показать порт SOCKS5 юзера
```

#### 3.2.2 Изменения в клиентах

**Клиентский YAML (`{user}_olcrtc.yaml`)** — почти не меняется. Единственное отличие: в `isolated` режиме клиент может НЕ указывать `claims` (сервер уже знает юзера по комнате). Но для единообразия claims остаётся.

**Windows CLI (`olcrtc-windows-amd64.exe`):**

Добавить флаг `--mode` для явного указания режима. Если не указан — `auto`, пытается определить по конфигу сервера.

```yaml
# shared — поведение как сейчас, claims опциональны
# isolated — клиент подключается к комнате юзера
mode: isolated
```

**olcboxME (Android):**

- Добавить поле `mode` в `Config` data class
- В `configureMobileTransport()` передавать mode
- В URI добавить опциональный параметр `&mode=...`:
  ```
  olcrtc://jitsi?datachannel&user=X&pass=Y&mode=isolated@ROOM#KEY$TAG
  ```
- В QR-код URI записывать mode

### 3.3 Потребление ресурсов

Каждый процесс olcrtc ≈ 50MB RAM при подключении. Для 20 юзеров ≈ 1GB.  
На сервере 2GB RAM — хватит.

---

## 4. Режим `dynamic` — диспетчер-комната

### 4.1 Принцип

Один процесс olcrtc слушает **комнату-диспетчер** (`pxy-76t05pyu.ikill.baby-dispatch`).  
Когда клиент подключается к диспетчеру, сервер:
1. Проверяет claims/UUID
2. Создаёт (или получает уже активную) сессию в **отдельной** временной комнате
3. Сообщает клиенту адрес новой комнаты через datachannel
4. Клиент переподключается к своей временной комнате
5. По таймауту неактивности — сессия и комната уничтожаются

### 4.2 Что нужно сделать

#### 4.2.1 Изменения в Go-коде olcRTC (сервер, `/root/pj/olcrtc/`)

**A. Пакет `internal/dispatch` — новый:**

```go
package dispatch

type Config struct {
    Enabled     bool          // включён ли режим
    DispatchRoom string       // комната-диспетчер
    SessionTTL  time.Duration // время жизни неактивной сессии
    MaxSessions int           // максимум параллельных сессий
    PortStart   int           // начало диапазона SOCKS5-портов
}

type Session struct {
    ID       string
    User     string
    Room     string
    Created  time.Time
    LastSeen time.Time
    Port     int
}

type Manager struct {
    mu       sync.RWMutex
    sessions map[string]*Session
    cfg      Config
}
```

Методы:
- `HandleConnection(ctx, conn, claims)` — создаёт/возвращает сессию, выделяет порт
- `SessionByUser(user)` — возвращает активную сессию
- `CleanupLoop(ctx)` — горутина, убивает сессии по TTL

**B. Изменения в `internal/app/session/session.go`:**

Добавить поле `Dispatch *dispatch.Manager` в `session.Config`.  
В `Run()`:
- Если `mode: dynamic` → запустить диспетчер
- Иначе → текущее поведение

**C. Изменения в `cmd/olcrtc/main.go`:**

Новый флаг `--mode` (shared|isolated|dynamic).  
При `dynamic`:
1. Парсим комнату-диспетчер из YAML
2. Запускаем `dispatch.New(cfg)`
3. Подключаемся к Jitsi
4. При входящем datachannel от клиента — передаём управление диспетчеру

**D. Протокол перенаправления:**

Клиент → Сервер (через datachannel после ICE):
```json
{
  "type": "dispatch",
  "claims": {"user": "Merlin", "pass": "..."}
}
```

Сервер → Клиент:
```json
{
  "type": "redirect",
  "room": "https://meet.egovm.ru/pxy-76t05pyu.ikill.baby-session-a1b2c3",
  "port": 11001
}
```

Клиент переподключается к новой комнате.

**E. Изменения в `internal/server/server.go`:**

В `dynamic` режиме сервер создаёт **два** подключения:
1. К комнате-диспетчеру (всегда)
2. К временной комнате клиента (после редиректа)

#### 4.2.2 Изменения в клиентах

**A. Пакет `internal/client/client.go`:**

Добавить `Mode` в `Config`.  
При `mode: dynamic`:
1. Подключиться к диспетчеру (комната из YAML)
2. Отправить `{"type": "dispatch", "claims": ...}`
3. Получить `{"type": "redirect", "room": ..., "port": ...}`
4. Переподключиться к новой комнате и порту
5. Запустить SOCKS5 на указанном порту

**B. Windows CLI — добавить `--mode` в main.go:**

```go
if cfg.Mode == "dynamic" {
    // run dispatch client logic
}
```

**C. olcboxME — `mobile/mobile.go`:**

- Добавить `SetMode(mode string)` (аналогично `SetClaims`)
- `startWithConfig` передаёт mode в client.Config
- Если `mode = dynamic` → логика редиректа прозрачна для пользователя

**D. olcbox URI — опциональный `&mode=dynamic`:**

```
olcrtc://jitsi?datachannel&user=X&pass=Y&mode=dynamic@DISPATCH_ROOM#KEY$TAG
```

После редиректа olcbox сам меняет комнату, пользователь ничего не замечает.

#### 4.2.3 Изменения в серверной конфигурации

```yaml
# Режим dynamic
mode: dynamic
dispatch:
  room: "https://meet.egovm.ru/pxy-76t05pyu.ikill.baby-dispatch"
  session_ttl: 5m
  max_sessions: 50
  port_start: 12000

auth:
  provider: jitsi
  users_file: /etc/olcrtc/users.json

crypto:
  key: "2967bab5e92bb2c9ceef2e0e9b7b65d1dabca7d7b2db8c005250a591d2ce4b31"

socks:
  host: 127.0.0.1
  port: 0               # 0 = порт назначается динамически
```

---

## 5. Матрица совместимости и переключения

### 5.1 Клиент → Сервер

| Клиент \ Сервер | shared | isolated | dynamic |
|----------------|--------|----------|---------|
| **claims** | ✅ работает | ✅ работает | ✅ работает |
| **UUID** | ✅ работает | ✅ (через default-комнату) | ✅ (через default-диспетчер) |
| **dynamic-клиент** | работает как shared | работает как isolated | ✅ полный dynamic |
| **isolated-клиент** | работает как shared | ✅ | нет, нужен перенастрой |

### 5.2 Миграция между режимами

```
shared ──add_user──→ isolated   # создаётся отдельная комната
shared ──migrate──→ isolated    # все существующие юзеры получают свои комнаты
isolated ──migrate──→ dynamic   # процессы заменяются сессиями диспетчера
dynamic ──→ shared              # пересоздать единую комнату
```

### 5.3 Флаг совместимости `compat.uuid`

В серверном YAML:

```yaml
compat:
  uuid: true   # разрешить подключение по UUID без claims
```

Если `false` — только claims. Если `true` — оба способа.

---

## 6. Поэтапный план реализации

### Фаза 1 — режим `isolated` (серверная часть)

1. Создать systemd template `olcrtc@.service`
2. Обновить `add_olcrtc_user` в `proxy_manager.sh`:
   - порт-аллокатор
   - генерация `{user}_olcrtc_server.yaml`
   - запуск systemd-юнита
3. Обновить `del_user`:
   - остановка systemd-юнита
   - очистка порта
4. Создать `olcrtc-admin` скрипт
5. Написать тест: 2 юзера, каждый в своей комнате, SOCKS5 на разных портах

### Фаза 2 — клиенты для `isolated`

1. Добавить `mode: isolated` в `{user}_olcrtc.yaml`
2. Windows CLI: `--mode` флаг (сейчас игнорируется, работает как shared)
3. Android: `SetMode` + параметр в URI

### Фаза 3 — режим `dynamic` (сервер)

1. Написать `internal/dispatch` пакет
2. Добавить протокол перенаправления (json через datachannel)
3. Интегрировать в `cmd/olcrtc/main.go`
4. Написать тест: клиент → диспетчер → редирект → своя комната

### Фаза 4 — клиенты для `dynamic`

1. `internal/client/client.go`: логика dispatch-рукопожатия
2. Windows CLI: `mode: dynamic`
3. `mobile/mobile.go`: `SetMode("dynamic")` + прозрачный редирект
4. Android: `&mode=dynamic` в URI

### Фаза 6 — mismatch recovery и correction message

1. Добавить `"type": "config_mismatch"` в протокол сервера
2. Реализовать обработку correction message в `internal/client/client.go` — авто-переподключение к правильной комнате
3. `mobile/mobile.go`: callback на correction message
4. Android: прозрачное переподключение при mismatch
5. `olcrtc-admin migrate` — после миграции отправляет correction всем активным клиентам
6. Флаги `allow_fallback` и `notify_on_mismatch` в `user_modes.json`

---

## 7. Файлы, которые изменятся

| Файл | Что меняется | Фаза |
|------|------------|------|
| `/root/.config/olcrtc/server.yaml` | поле `mode`, `dispatch`, `compat` | 1 |
| `/root/proxy_manager.sh` | `add_olcrtc_user`, `del_user`, порт-аллокатор | 1 |
| `/etc/systemd/system/olcrtc@.service` | новый template unit | 1 |
| `/root/pj/olcrtc/cmd/olcrtc/main.go` | парсинг mode, запуск диспетчера | 1,3 |
| `/root/pj/olcrtc/internal/app/session/session.go` | `Dispatch` поле, `Run` логика | 1,3 |
| `/root/pj/olcrtc/internal/server/server.go` | два подключения в dynamic | 3 |
| `/root/pj/olcrtc/internal/client/client.go` | dispatch-рукопожатие | 4 |
| `/root/pj/olcrtc/internal/dispatch/dispatch.go` | **новый** пакет | 3 |
| `/root/pj/olcrtc/mobile/mobile.go` | `SetMode` | 2,4 |
| `/root/pj/olcbox/sharedUI/.../OlcboxVpnService.kt` | mode из Config | 2,4 |
| `/root/pj/olcbox/sharedUI/.../OlcRtcConnectionChecker.kt` | mode | 2,4 |
| `/opt/proxy-panel/app.py` | отображение режима, порта | 1 |
| `/opt/proxy-panel/templates/index.html` | колонка режима | 1 |

---

## 8. Критерии готовности

- [ ] `proxy_manager.sh add_olcrtc_user` в режиме `isolated` создаёт отдельную комнату + systemd unit
- [ ] Клиент подключается к своей комнате, другой клиент не видит его ICE
- [ ] `del_user` чистит комнату и сервис
- [ ] В режиме `dynamic` клиент через диспетчер получает редирект в свою комнату
- [ ] `compat.uuid: true` — UUID-клиенты работают во всех режимах
- [ ] `olcrtc-windows-amd64.exe` работает во всех 3 режимах
- [ ] `olcbox-me-release.apk` работает во всех 3 режимах
- [ ] Миграция между режимами без потери пользователей
- [ ] Correction message — клиент сам переподключается при смене комнаты на сервере
- [ ] `allow_fallback` — старый клиент без редиректа работает через shared fallback

---

## 9. Репозитории и публикация

### 9.1 Куда заливать

| Компонент | Репозиторий | Ветка |
|-----------|-------------|-------|
| Go-код olcRTC (сервер, dispatch, client) | `smartor777-sketch/olcrtc-users` | `main` |
| Android-клиент olcboxME | `smartor777-sketch/olcbox-me` | `main` |
| APK-релизы | `smartor777-sketch/olcbox-me` → **GitHub Releases** | тег `v{version}` |
| Windows CLI-релизы | `smartor777-sketch/olcrtc-users` → **GitHub Releases** | тег `v{version}` |

### 9.2 Процесс публикации

**olcRTC (сервер + Windows CLI):**

```bash
cd /root/pj/olcrtc
git remote set-url origin https://github.com/smartor777-sketch/olcrtc-users.git

# После внесения изменений
git add -A && git commit -m "feat: dispatch mode, isolated sessions"
git push origin main

# Собрать и выложить релиз
GOOS=windows GOARCH=amd64 go build -o olcrtc-windows-amd64.exe ./cmd/olcrtc
gh release create v0.9.0 olcrtc-windows-amd64.exe --title "olcRTC v0.9.0 — dynamic dispatch" --notes "..."

# Обновить ссылку в AppUpdateService.kt
```

**olcboxME (Android):**

```bash
cd /root/pj/olcbox
git remote set-url origin https://github.com/smartor777-sketch/olcbox-me.git

git add -A && git commit -m "feat: multi‑room mode support"
git push origin main

# Собрать и выложить APK
./gradlew :androidApp:assembleRelease
cp androidApp/build/outputs/apk/release/androidApp-release.apk olcbox-me-v0.9.0.apk
gh release create v0.9.0 olcbox-me-v0.9.0.apk --title "olcboxME v0.9.0 — multi‑room" --notes "..."
```

### 9.3 Обновление Update URL

После публикации релиза `v0.9.0` в `smartor777-sketch/olcbox-me`, приложение само найдёт обновление через GitHub API — URL уже перешит в `AppUpdateService.kt`:

```kotlin
repositoryUrl = "https://github.com/smartor777-sketch/olcbox-me"
```

---

## 10. Управляющий скрипт `olcrtc-admin` и прозрачность для клиента

### 10.1 Принцип

Клиент **не знает и не выбирает** режим сервера. Он просто подключается с claims/UUID к комнате из своего YAML.  
Всю логику выбора режима берёт на себя **управляющий скрипт на сервере** и **серверная конфигурация**.

```
Клиент (любой):
  config.yaml: room, crypto.key, claims → socks 127.0.0.1:1082

Сервер:
  ┌─ shared    — один процесс, комната общая
  ├─ isolated  — N процессов, каждому своя комната
  └─ dynamic   — диспетчер, сессии на лету
```

Клиенту всё равно — он получает готовый YAML/URI от панели, открывает SOCKS5 на `127.0.0.1:1082` и работает.

### 10.2 `olcrtc-admin` — управляющий скрипт

**Путь:** `/usr/local/bin/olcrtc-admin`
**Язык:** Bash (как `proxy_manager.sh`)

#### Команды

```
olcrtc-admin mode                          # показать текущий режим сервера
olcrtc-admin mode set shared|isolated|dynamic  # глобальный режим

olcrtc-admin user mode <user>              # показать режим конкретного юзера
olcrtc-admin user mode set <user> <mode>   # назначить режим юзеру (override)
olcrtc-admin user mode reset <user>        # сбросить на глобальный

olcrtc-admin user add <user>               # добавить юзера в olcRTC (авто-выбор режима)
olcrtc-admin user remove <user>            # удалить юзера из olcRTC
olcrtc-admin user list                     # список юзеров с режимами и портами

olcrtc-admin rooms                         # список всех активных комнат
olcrtc-admin port <user>                   # показать SOCKS5-порт юзера (для отладки)

olcrtc-admin config shared <user>          # сгенерировать YAML для shared-режима
olcrtc-admin config isolated <user>        # сгенерировать YAML для isolated-режима
olcrtc-admin config dynamic <user>         # сгенерировать YAML для dynamic-режима
olcrtc-admin config auto <user>            # сгенерировать YAML по текущему режиму юзера

olcrtc-admin migrate shared-to-isolated    # перенести всех юзеров в isolated
olcrtc-admin migrate isolated-to-dynamic   # перенести в dynamic
olcrtc-admin migrate dynamic-to-shared     # свернуть обратно в единую комнату
```

#### Меню (запуск без аргументов)

```
=========================================
    🎛️  olcRTC Multi‑Room Manager
=========================================
Глобальный режим: shared | isolated | dynamic

1. Показать конфигурацию сервера
2. Сменить глобальный режим
3. Показать юзеров и их режимы
4. Назначить режим юзеру
5. Сбросить режим юзера на глобальный
6. Сгенерировать YAML для юзера
7. Миграция между режимами
8. Показать активные комнаты
0. Выход
```

### 10.3 Комбинации режимов (пер-юзер)

Глобальный режим + пер-юзер override:

```
Глобальный: shared
  ├─ user1: shared (default)
  ├─ user2: isolated  ← override
  └─ user3: dynamic   ← override

Глобальный: isolated
  ├─ user1: isolated (default)
  ├─ user2: shared    ← override
  └─ user3: dynamic   ← override
```

**Где хранятся настройки:** `/root/.config/olcrtc/user_modes.json`

```json
{
  "global": "shared",
  "users": {
    "Merlin": "isolated",
    "VIP": "dynamic"
  }
}
```

### 10.4 Как `olcrtc-admin` реализует каждый режим

| Режим | Что делает скрипт |
|-------|------------------|
| **shared** | Проверяет, что основной `olcrtc.service` запущен. Генерирует YAML с общей комнатой. |
| **isolated** | Запускает `olcrtc@{user}.service` (systemd template). Генерирует YAML с уникальной комнатой `pxy-{domain}-{user}` и портом `11000+N`. |
| **dynamic** | Проверяет, что `olcrtc-dispatch.service` запущен (специальная сборка с диспетчером). Генерирует YAML с комнатой-диспетчером. |

### 10.5 Прозрачность для клиентов (главное правило)

**Клиент никогда не указывает `mode`.** Ни в YAML, ни в olcbox URI, ни в `SetMode()`.

Клиентский YAML всегда один и тот же:
```yaml
mode: cnc
auth:
  provider: jitsi
room:
  id: "..."      # комнату определяет скрипт при генерации
crypto:
  key: "..."
claims:
  user: USER
  pass: PASS
socks:
  host: 127.0.0.1
  port: 1082
```

Разные режимы → **разные комнаты в YAML**, клиент этого не замечает:
- **shared**: `room.id: meet.egovm.ru/pxy-76t05pyu.ikill.baby`
- **isolated**: `room.id: meet.egovm.ru/pxy-76t05pyu.ikill.baby-merlin`
- **dynamic**: `room.id: meet.egovm.ru/pxy-76t05pyu.ikill.baby-dispatch`

Панель при скачивании конфига отдаёт YAML с правильной комнатой — клиент просто работает.

### 10.6 Что меняется в клиентах (минимально)

**Windows CLI (`olcrtc-windows-amd64.exe`):**

Убрать `--mode` (клиенту не нужен). Комната берётся из YAML как сейчас.  
Единственное добавление: если сервер в dynamic-режиме прислал редирект — клиент **автоматически переподключается** к новой комнате. Пользователь ничего не видит.

```go
// В client.go — новый метод handleRedirect():
func (c *Client) handleRedirect(msg DispatchMessage) error {
    c.cfg.RoomID = msg.Room   // новая комната от сервера
    c.cfg.SOCKSPort = msg.Port // новый порт от сервера
    return c.reconnect()       // переподключение прозрачно
}
```

**Android (olcboxME):**

Убрать `SetMode()` из `mobile/mobile.go`.  
Добавить `SetDispatcherCallback(callback)` — вызывается, когда сервер в dynamic-режиме прислал редирект:

```kotlin
// Mobile.java (gomobile)
public static void SetDispatcherCallback(DispatcherCallback cb) {
    dispatcherCallback = cb;
}

// DispatcherCallback.java
public interface DispatcherCallback {
    void onRedirect(String newRoom, int newPort);
}
```

Android-сервис:
```kotlin
Mobile.SetDispatcherCallback(object : DispatcherCallback {
    override fun onRedirect(newRoom: String, newPort: Int) {
        // прозрачно переподключаемся без участия пользователя
        reconnectWith(newRoom, newPort)
    }
})
```

### 10.7 Интеграция с веб-панелью

В `/opt/proxy-panel/templates/index.html` добавить колонку **"Mode"**:

| User | hy2 | awg | ... | olcRTC | Mode | Actions | Delete |
|------|-----|-----|-----|--------|------|---------|--------|
| Merlin | + | + | ... | + | shared | ... | ✕ |
| test | - | + | ... | + | **isolated** | ... | ✕ |

Через панель можно сменить режим юзеру (выпадающий список → `olcrtc-admin user mode set`).

### 10.8 Сводка — что делает клиент vs что делает сервер

```
                    ┌──────────────────────────────┐
                    │       olcrtc-admin            │
                    │  (управление режимами)         │
                    └──────────┬───────────────────┘
                               │
                    ┌──────────▼───────────────────┐
                    │  Серверная конфигурация        │
                    │  user_modes.json               │
                    │  + room allocation             │
                    └──────────┬───────────────────┘
                               │
          ┌────────────────────┼────────────────────┐
          ▼                    ▼                    ▼
   ┌──────────┐       ┌──────────────┐     ┌──────────────┐
   │  shared   │       │   isolated   │     │   dynamic    │
   │  процесс  │       │  N процессов │     │  диспетчер   │
   └──────────┘       └──────────────┘     └──────────────┘
          │                    │                    │
          └────────────────────┼────────────────────┘
                               │
                    ┌──────────▼───────────────────┐
                    │  Клиент (всегда одинаковый)   │
                    │  config.yaml → SOCKS5:1082    │
                    │  claims или UUID              │
                    └──────────────────────────────┘
```

**Итог:** клиент не пересобирается при смене режима.  
Всё управление — через `olcrtc-admin` и веб-панель.

---

## 11. Протокол ошибок: сервер → клиент

Если конфиг клиента не совпадает с серверным — сервер **шлёт сообщение с типом ошибки** по data channel, чтобы клиент мог показать пользователю понятное описание и, где возможно, автоматически исправиться.

### 11.1 Формат сообщения

```json
{
  "type": "config_error",
  "error": {
    "code": "USER_NOT_FOUND",
    "message": "Пользователь 'Merlin' не найден в users.json",
    "details": {
      "field": "claims.user",
      "expected": "один из: test, Katya, admin",
      "got": "Merlin"
    },
    "recovery": [
      "Скачайте новый конфиг с панели https://76t05pyu.ikill.baby:8443/panel/",
      "Или обратитесь к администратору"
    ],
    "auto_recoverable": false
  }
}
```

Поля:
- `code` — машинный код ошибки (см. таблицу ниже)
- `message` — человекочитаемое описание на русском
- `details` — что именно не совпало (`field` / `expected` / `got`)
- `recovery` — массив строк-инструкций для пользователя
- `auto_recoverable` — `true` если клиент может сам переподключиться (например при `ROOM_CHANGED`)

### 11.2 Коды ошибок

| Код | Когда возникает | auto_recoverable |
|-----|----------------|------------------|
| `USER_NOT_FOUND` | claims.user нет в users.json | нет |
| `USERNAME_MISMATCH` | claims.user не совпадает с именем в YAML | нет |
| `PASSWORD_MISMATCH` | claims.pass не совпадает с users.json | нет |
| `ROOM_MISMATCH` | комната в YAML не совпадает с комнатой юзера на сервере | **да** (correction message) |
| `CRYPTO_KEY_MISMATCH` | crypto.key не совпадает с серверным | нет |
| `UUID_DISABLED` | клиент без claims, а сервер в режиме `compat.uuid: false` | нет |
| `MODE_MISMATCH` | режим юзера изменился, нужна другая комната | **да** (редирект) |
| `CLIENT_TOO_OLD` | клиент не понимает протокол (редирект / error) | нет |
| `SESSION_LIMIT` | превышен лимит сессий в dynamic-режиме | нет |

### 11.3 Сценарии ошибок и ответ сервера

#### Сценарий 1 — claims.user не найден в users.json

Клиент подключился с YAML, где `claims.user = "Merlin"`, но юзер был удалён.

```
Канал открылся (crypto.key совпадает).
Клиент → сервер: {"claims": {"user": "Merlin", "pass": "xxx"}}
Сервер → users.json → не нашёл.
Сервер → клиент:
{
  "type": "config_error",
  "error": {
    "code": "USER_NOT_FOUND",
    "message": "Пользователь 'Merlin' не найден в users.json",
    "details": {
      "field": "claims.user",
      "expected": "один из: test, Katya, admin",
      "got": "Merlin"
    },
    "recovery": [
      "Скачайте новый конфиг с панели https://76t05pyu.ikill.baby:8443/panel/"
    ],
    "auto_recoverable": false
  }
}
Сервер закрывает data channel.
```

Клиент показывает сообщение пользователю. Не переподключается — смысла нет.

#### Сценарий 2 — пароль не совпадает

```json
{
  "type": "config_error",
  "error": {
    "code": "PASSWORD_MISMATCH",
    "message": "Неверный пароль для пользователя 'Merlin'",
    "details": {
      "field": "claims.pass",
      "got": "wrongpassword"
    },
    "recovery": [
      "Скачайте новый конфиг с панели https://76t05pyu.ikill.baby:8443/panel/",
      "Если вы помните пароль — введите его заново в клиенте"
    ],
    "auto_recoverable": false
  }
}
```

#### Сценарий 3 — комната не совпадает (миграция shared→isolated)

Сервер видит claims юзера, находит его в `user_modes.json` с режимом `isolated`, но клиент подключился к `shared`-комнате.

```json
{
  "type": "config_error",
  "error": {
    "code": "ROOM_MISMATCH",
    "message": "Ваш профиль перемещён в отдельную комнату",
    "details": {
      "field": "room.id",
      "expected": "meet.egovm.ru/pxy-76t05pyu.ikill.baby-merlin",
      "got": "meet.egovm.ru/pxy-76t05pyu.ikill.baby"
    },
    "recovery": [
      "Клиент автоматически переподключится к правильной комнате"
    ],
    "auto_recoverable": true,
    "correct_room": "meet.egovm.ru/pxy-76t05pyu.ikill.baby-merlin",
    "correct_port": 11001
  }
}
```

Клиент, поддерживающий `auto_recoverable: true`, **автоматически переподключается** к `correct_room:correct_port` без участия пользователя.  
Клиент без поддержки — показывает ошибку.

#### Сценарий 4 — crypto.key не совпадает

DTLS handshake не проходит — data channel **не открывается**. Сообщение отправить нельзя (канала нет).

**Решение:** сообщение об ошибке генерируется на **этапе установки data channel** — если DTLS упал с `bad record MAC`, клиент сам пишет:

> Ошибка: ключ шифрования не совпадает с серверным. Скачайте новый конфиг в панели.

Тип ошибки выводится из анализа ошибки DTLS:

```
DTLS error: bad record MAC → code: CRYPTO_KEY_MISMATCH
DTLS error: handshake failure, no shared cipher → code: CRYPTO_KEY_MISMATCH
```

#### Сценарий 5 — старый клиент в dynamic-режиме

Клиент не знает протокол редиректа, но подключается к dispatch-комнате.

```json
{
  "type": "config_error",
  "error": {
    "code": "CLIENT_TOO_OLD",
    "message": "Версия клиента устарела для dynamic-режима",
    "details": {
      "field": "client.version",
      "expected": ">= 0.9.0",
      "got": "0.8.0"
    },
    "recovery": [
      "Обновите приложение до последней версии",
      "Или используйте shared-режим (скачайте конфиг для shared)"
    ],
    "auto_recoverable": false
  }
}
```

#### Сценарий 6 — неправильное имя пользователя в YAML (опечатка)

Клиент подключился с `claims.user = "Marlin"` (вместо `"Merlin"`).

```json
{
  "type": "config_error",
  "error": {
    "code": "USERNAME_MISMATCH",
    "message": "Пользователь 'Marlin' не найден. Возможно, опечатка?",
    "details": {
      "field": "claims.user",
      "suggestions": ["Merlin", "Katya", "test"],
      "got": "Marlin"
    }
  }
}
```

Поле `suggestions` — сервер ищет ближайшее совпадение по Damerau-Levenshtein.

### 11.4 Обработка на клиенте

**Windows CLI (olcrtc-windows-amd64.exe):**

```
[!] Ошибка конфига: Пользователь 'Marlin' не найден
    Возможно, вы имели в виду: Merlin, Katya, test
    Скачайте новый конфиг: https://76t05pyu.ikill.baby:8443/panel/
```

**Android (olcboxME):**

```
[Toast / Notification]
╔══════════════════════════════╗
║  Ошибка конфигурации        ║
║                              ║
║  Код: USERNAME_MISMATCH     ║
║  Пользователь 'Marlin'      ║
║  не найден. Возможно,       ║
║  опечатка?                  ║
║                              ║
║  [ Открыть панель ]         ║
╚══════════════════════════════╝
```

Кнопка "Открыть панель" ведёт в браузер на URL панели.

### 11.5 Реализация на сервере

После открытия data channel, но ДО начала прокси-трафика:

```go
type ConfigError struct {
    Type  string      `json:"type"` // "config_error"
    Error ErrorDetail `json:"error"`
}

type ErrorDetail struct {
    Code            string   `json:"code"`
    Message         string   `json:"message"`
    Details         any      `json:"details,omitempty"`
    Recovery        []string `json:"recovery,omitempty"`
    AutoRecoverable bool     `json:"auto_recoverable"`
    CorrectRoom     string   `json:"correct_room,omitempty"`
    CorrectPort     int      `json:"correct_port,omitempty"`
}
```

В `session.go`, после `Validate`:

```go
func (s *Session) validateConfig() error {
    // 1. Проверить claims → users.json
    user, err := s.findUser(s.Claims.User)
    if err != nil {
        return s.sendError(ConfigError{
            Code:    "USER_NOT_FOUND",
            Message: fmt.Sprintf("Пользователь '%s' не найден", s.Claims.User),
            Details: map[string]any{
                "field": "claims.user",
                "got":   s.Claims.User,
            },
        })
    }
    // 2. Проверить пароль
    if user.Password != s.Claims.Pass {
        return s.sendError(ConfigError{
            Code:    "PASSWORD_MISMATCH",
            Message: fmt.Sprintf("Неверный пароль для '%s'", s.Claims.User),
        })
    }
    // 3. Проверить комнату (если есть user_modes.json)
    // 4. Проверить crypto.key (сравнить с server.yaml)
    return nil
}
```

### 11.6 Client‑side recovery (уточнение)

| Код | Клиент делает |
|-----|---------------|
| `USER_NOT_FOUND` | Показывает ошибку, НЕ переподключается |
| `PASSWORD_MISMATCH` | Показывает ошибку, предлагает скачать новый конфиг |
| `ROOM_MISMATCH` | **Авто-переподключение** к correct_room:correct_port |
| `MODE_MISMATCH` | **Авто-переподключение** к correct_room:correct_port |
| `CRYPTO_KEY_MISMATCH` | Показывает ошибку, НЕ переподключается |
| `CLIENT_TOO_OLD` | Предлагает обновить приложение |
| `SESSION_LIMIT` | Показывает "Сервер занят, попробуйте позже" |

### 11.7 Критически важное правило безопасности

Сервер шлёт подробную ошибку **только когда он уверен, кто клиент**.  
Если клиент **не идентифицирован** — никакой помощи, никакого fallback-доступа.

**Разрешаем помощь:**

| Условие | Сервер знает юзера? | Действие |
|---------|------------------|----------|
| claims.user найден в users.json | ✅ Да | Шлёт `PASSWORD_MISMATCH`, `ROOM_MISMATCH`, и т.д. |
| claims.user найден, пароль неверный | ✅ Да | Шлёт `PASSWORD_MISMATCH` с recovery |
| UUID найден, совпал | ✅ Да | Шлёт `MODE_MISMATCH` с correct_room |
| claims.user отсутствует, UUID не совпал | ❌ Нет | Шлёт `USER_NOT_FOUND` **без details / suggestions** |

**Никогда:**

- ❌ Не давать shared fallback клиенту, которого нет в users.json
- ❌ Не выдавать список пользователей в `suggestions`, если claims.user пустой
- ❌ Не открывать SOCKS5-порт пока авторизация не прошла
- ❌ Не сохранять сессию в `user_modes.json` для неавторизованного клиента

**Пример — неопознанный клиент:**

```json
{
  "type": "config_error",
  "error": {
    "code": "USER_NOT_FOUND",
    "message": "Пользователь не опознан. Проверьте конфиг.",
    "details": {},
    "recovery": [
      "Скачайте новый конфиг с панели"
    ],
    "auto_recoverable": false
  }
}
```

Без `suggestions`, без `expected` — только общее сообщение.  
Сервер не даёт информацию, которую можно использовать для брутфорса.

**Пример — опознанный клиент (неверный пароль):**

```json
{
  "type": "config_error",
  "error": {
    "code": "PASSWORD_MISMATCH",
    "message": "Неверный пароль для пользователя 'Merlin'",
    "details": {
      "field": "claims.pass",
      "got": "wrongpass"
    },
    "recovery": ["Скачайте новый конфиг"],
    "auto_recoverable": false
  }
}
```

Сервер знает, что это Merlin, но пароль неверный — даём точную подсказку.  
Брутфорс не страшен: пароль в YAML, не вводится руками.

**Правило для реализации:**

```go
func (s *Session) validateConfig() error {
    user, err := s.findUser(s.Claims.User, s.Claims.UUID)
    if err != nil || user == nil {
        // Неопознан — общий ответ, без деталей
        return s.sendError(ConfigError{
            Code:    "USER_NOT_FOUND",
            Message: "Пользователь не опознан. Проверьте конфиг.",
        })
    }
    // Опознан — можно помогать
    if user.Password != s.Claims.Pass {
        return s.sendError(ConfigError{
            Code:    "PASSWORD_MISMATCH",
            Message: fmt.Sprintf("Неверный пароль для '%s'", user.Name),
            Details: map[string]any{
                "field": "claims.pass",
                "got":   s.Claims.Pass,
            },
        })
    }
    return nil
}
```

---

### 9.4 Структура релизов

```
smartor777-sketch/olcbox-me
├── v0.9.0          # olcbox-me-v0.9.0.apk (Android)
├── v0.9.1          # olcbox-me-v0.9.1.apk

smartor777-sketch/olcrtc-users
├── v0.9.0          # olcrtc-windows-v0.9.0.exe, olcrtc-linux-v0.9.0
├── v0.9.1          # olcrtc-windows-v0.9.1.exe, olcrtc-linux-v0.9.1
```

# Telegram WEB Proxy — полный гайд

## Что это

Telegram WEB Proxy (`tproxy-server`) — это серверный компонент, который позволяет клиентам Telegram (Desktop, Android, iOS) проксировать MTProto-трафик через HTTPS/WebSocket. Клиент открывает WebView с прокси-страницей, внутри которого работает адаптер, мультиплексирующий MTProto-сессии поверх HTTP-транспорта.

Архитектура состоит из трёх компонентов:

```
Telegram клиент
    │  MTProto framing + шифрование
    ▼
WebView (локальный адаптер)
    │  multiplexed streams (логические сессии)
    ▼
carrier (HTTPS / WebSocket)  ← carrier_mode определяет транспорт
    │
    ▼
tproxy-server (:8090)  ← Go relay, мультиплексирует сессии
    │  TCP
    ▼
mtproto-proxy (:2398)  ← official MTProxy от Telegram
    │  MTProto
    ▼
Telegram DC (91.108.x.x:8888)
```

## Секреты — самое важное

### Два типа секретов

В системе два **независимых** секрета:

| Где используется | Формат | Где задаётся |
|---|---|---|
| **mtproto-proxy** `-S` флаг | 32 hex символа | `mtproxy.env` → `MTPROXY_SECRET` |
| **tproxy-server** профиль `secret` | 32 hex символа | `profiles.json` |

### Главное правило

**Secret в профиле (`profiles.json`) должен совпадать с `-S` секретом mtproto-proxy**, к которому подключается этот профиль.

Почему: клиент вводит ключ (32 hex) → MTProto-клиент использует его для шифрования трафика → mtproto-proxy должен расшифровать этот трафик своим `-S` секретом. Если секреты не совпадают — соединение устанавливается, но трафик не проходит.

### Множество mtproxy — множество секретов

Если нужно несколько независимых профилей с разными секретами, запускается **отдельный mtproto-proxy** на другом порту с другим секретом:

| mtproto-proxy порт | `-S` секрет | Профили |
|---|---|---|
| `:2398` | `2b13b941...` | default, Alex |
| `:2399` | `c22e6983...` | Triton |

Каждый mtproxy требует **свои** `proxy-secret` и `proxy-multi.conf` (обновляются из Telegram API).

## Carrier Modes (режимы транспорта)

Carrier mode определяет, как клиентский WebView отправляет MTProto-данные через HTTP к tproxy-server.

### `https` (по умолчанию)

**Как работает:** все логические сессии мультиплексируются в **одном** HTTPS-соединении. Клиент открывает один HTTP-запрос и шлёт все данные через него.

```
Клиент ──[одно HTTPS соединение]──▶ tproxy-server
        stream1, stream2, stream3  (мультиплекс)
```

- Максимальная совместимость с прокси/файрволами
- Простейшая настройка
- Один коннект — узкое место при большой нагрузке
- **Рекомендация:** по умолчанию, для малых/средних серверов

### `https-lanes`

**Как работает:** каждая логическая сессия — **отдельный** HTTPS-запрос (своя «дорожка»). Параллельно открыто N соединений по числу активных сессий.

```
Клиент ──[HTTPS 1]──▶ stream1
       ──[HTTPS 2]──▶ stream2
       ──[HTTPS 3]──▶ stream3
```

- Лучшая изоляция: проблемы одной сессии не затрагивают другие
- Проще балансировать, проще дебажить
- Больше HTTP-overhead (каждая лента — отдельный запрос)
- **Рекомендация:** умеренная нагрузка, когда важна изоляция

### `websocket`

**Как работает:** одно мультиплексированное **WebSocket**-соединение на все сессии. WebSocket — полноценный двунаправленный канал, без overhead HTTP-запросов.

```
Клиент ══[WebSocket]══▶ tproxy-server
        stream1, stream2, stream3  (мультиплекс)
```

- Нет overhead от HTTP-запросов (установка соединения один раз)
- Двунаправленный канал — ниже латентность
- Может не работать за некоторыми прокси/CDN (мешает upgrade-заголовок)
- **Рекомендация:** серверы с постоянными подключениями, когда нет промежуточных прокси

### `websocket-lanes`

**Как работает:** каждая сессия — **отдельный** WebSocket. Максимальная изоляция при минимальном overhead.

```
Клиент ══[WS 1]══▶ stream1
       ══[WS 2]══▶ stream2
       ══[WS 3]══▶ stream3
```

- Максимальная изоляция + низкий overhead WebSocket
- Больше ресурсов (отдельное WS-соединение на каждую сессию)
- **Рекомендация:** высоконагруженные серверы, изоляция пользователей

### Сравнительная таблица

| Режим | Мультиплекс | Изоляция | HTTP-overhead | Ресурсы | За прокси/CDN |
|---|---|---|---|---|---|
| `https` | Одно соединение | Низкая | Средний | Минимальные | ✅ |
| `https-lanes` | N соединений | Средняя | Высокий | Средние | ✅ |
| `websocket` | Одно WS | Низкая | Низкий | Средние | ⚠️ |
| `websocket-lanes` | N WS | Высокая | Низкий | Высокие | ⚠️ |

**Все 4 режима работают и протестированы** на prod (87.120.186.100).

### Как выбрать режим

1. **Начните с `https`** — дефолт, работает везде
2. Если нужна **изоляция** между пользователями → `https-lanes` или `websocket-lanes`
3. Если **нет промежуточных прокси/CDN** и нужна низкая латентность → `websocket` или `websocket-lanes`
4. **Высокая нагрузка** → `websocket-lanes`

Переключение между режимами — через панель NYX (`/self/tproxy`) или правкой `profiles.json`:

```bash
# Через панель
# Страница /self/tproxy → кнопки HTTPS / Lanes / WS / WS Lanes

# Или вручную
python3 -c "
import json
with open('/etc/tproxy-server/profiles.json') as f:
    data = json.load(f)
for p in data['profiles']:
    if p['name'] == 'default':
        p['carrier_mode'] = 'websocket-lanes'
with open('/etc/tproxy-server/profiles.json', 'w') as f:
    json.dump(data, f, indent=2)
"
systemctl restart tproxy-server
```

## Конфигурация

### profiles.json

```json
{
  "profiles": [
    {
      "name": "default",
      "secret": "2b13b941f042b5e991d0685cfb81c96c",
      "backend": "127.0.0.1:2398",
      "carrier_mode": "https"
    },
    {
      "name": "Triton",
      "secret": "c22e69834dd221287c24f9673e66c42f",
      "backend": "127.0.0.1:2399",
      "carrier_mode": "websocket-lanes"
    }
  ]
}
```

| Поле | Описание |
|---|---|
| `name` | Имя профиля (для отображения в панели) |
| `secret` | 32 hex — **должен совпадать** с `-S` секретом mtproxy на `backend` порту |
| `backend` | Адрес mtproto-proxy `host:port` |
| `carrier_mode` | `https` / `https-lanes` / `websocket` / `websocket-lanes` |

### config.json

```json
{
  "listen": ":8090",
  "admin_listen": "127.0.0.1:8081",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json",
  "access_log": true
}
```

## Порты

| Порт | Сервис | Внешний доступ | Описание |
|---|---|---|---|
| 80 | Caddy | ✅ | HTTP → HTTPS redirect |
| 443 | Caddy | ✅ | Панель + tg.kuban-forum.ru |
| 2398 | mtproxy (default) | ❌ | Backend для default/Alex |
| 2399 | mtproxy-triton | ❌ | Backend для Triton |
| 8090 | tproxy-server | ❌ (loopback) | Relay (принимает Caddy) |
| 8081 | tproxy-server admin | ❌ (loopback) | Админка /metrics /healthz |

## Диагностика

```bash
# Статус сервисов
systemctl status tproxy-server mtproxy mtproxy-triton

# Relay готов
curl http://127.0.0.1:8081/readyz

# Метрики
curl http://127.0.0.1:8081/metrics
# tproxy_sessions_live — активные сессии
# tproxy_bytes_up_total / tproxy_bytes_down_total — трафик
# tproxy_streams_opened_total — открытые потоки
# tproxy_backend_dial_failures_total — ошибки подключения к mtproxy

# Логи tproxy-server
journalctl -u tproxy-server --since '5 min ago'

# Логи mtproxy
journalctl -u mtproxy --since '5 min ago'

# Соединения mtproxy с DC
ss -tnp | grep mtproto-proxy | grep -v '127.0.0.1' | head -10

# Firewall
nft list table inet tproxy_backend

# Проверка что порты mtproxy не对外开放
nc -vz -w 3 87.120.186.100 2398  # должен не отвечать
nc -vz -w 3 87.120.186.100 2399  # должен не отвечать
```

### Типичные проблемы

| Симптом | Причина | Решение |
|---|---|---|
| "Подключено", но нет трафика | Secret профиля не совпадает с `-S` mtproxy | Проверить `profiles.json` secret и `mtproxy.env` MTPROXY_SECRET |
| tproxy-server падает с ошибкой `invalid character '\\'` | Сломанный JSON в `config.json` | Проверить/перезаписать config.json |
| SYN-SENT на все DC соединения | `IPAddressDeny=any` в systemd сервисе mtproxy | Убрать restrictive директивы из mtproxy.service |
| carrier_mode не применяется | Не перезапущен tproxy-server | `systemctl restart tproxy-server` |
| `carrier_mode: "ws"` — падает | `ws` — невалидное значение | Использовать `websocket` |
| Внешний доступ к :2398/:2399 | nftables не блокирует | Проверить `nft list table inet tproxy_backend` |

## Управление через NYX Panel

На продакшене доступно по адресу `https://panel.kuban-forum.ru/self/tproxy`:

- **Список профилей** с текущим режимом и кнопками переключения
- **Добавление профиля** — имя, автоматическая генерация секрета
- **Редактирование** — смена секрета, режима
- **Удаление** профиля
- **Info** — показать Host + Key для подключения в Telegram

## Ссылки

- [tproxy-server README](https://github.com/telegramdesktop/tproxy-server/blob/master/README.md)
- [tproxy-server PROTOCOL](https://github.com/telegramdesktop/tproxy-server/blob/master/PROTOCOL.md)
- [tproxy-server PLAN](https://github.com/telegramdesktop/tproxy-server/blob/master/PLAN.md)

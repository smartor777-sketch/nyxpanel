# Telegram WEB Proxy — Carrier Modes

tproxy-server поддерживает 4 режима доставки данных (carrier_mode) внутри Telegram WEB Proxy.

## Общая архитектура

```
Telegram App
│  MTProto framing + encryption
▼
Local WEB adapter (WebView)
│  multiplexed logical streams
▼
carrier (HTTPS / WebSocket)
│
▼
tproxy-server → TCP → official MTProxy → Telegram DC
```

## Режимы

### `https` (по умолчанию)

Все логические сессии мультиплексируются в **одном** HTTPS-соединении.

- Простейший режим, максимальная совместимость
- При большом количестве пользователей одно соединение может стать узким местом
- Подходит для: небольших деплоев, тестирования

### `https-lanes`

Каждая логическая сессия получает **свой** HTTPS-запрос (независимые "дорожки").

- Лучшая изоляция между сессиями
- Проще балансировать нагрузку
- Подходит для: серверов с умеренной нагрузкой

### `websocket`

Одно мультиплексированное WebSocket-соединение на все сессии.

- Эффективнее HTTPS для постоянных подключений (нет overhead HTTP-запросов)
- WebSocket — "живой" канал, не нужно перезапрашивать
- Может не работать за некоторыми прокси/CDN (мешает upgrade-заголовок)
- Подходит для: серверов с постоянными подключениями, без промежуточных прокси

### `websocket-lanes`

Каждая сессия — **отдельный** WebSocket.

- Максимальная изоляция и производительность
- Больше ресурсов на сервере (отдельное WS-соединение на каждую сессию)
- Подходит для: высоконагруженных серверов

## Сравнение

| Режим | Мультиплекс | Изоляция | HTTP-overhead | Ресурсы | За прокси/CDN |
|---|---|---|---|---|---|
| `https` | Одно соединение | Низкая | Средний | Минимальные | ✅ |
| `https-lanes` | N соединений | Средняя | Высокий | Средние | ✅ |
| `websocket` | Одно WS | Низкая | Низкий | Средние | ⚠️ |
| `websocket-lanes` | N WS | Высокая | Низкий | Высокие | ⚠️ |

## Критически важное правило

**Secret профиля в `profiles.json` должен совпадать с `-S` секретом mtproto-proxy**, к которому подключается этот профиль. Если секреты не совпадают — соединение установится, но трафик не пройдёт.

## Конфигурация

Режим задаётся в `/etc/tproxy-server/profiles.json`:

```json
{
  "profiles": [
    {
      "name": "default",
      "secret": "0123456789abcdef0123456789abcdef",
      "backend": "127.0.0.1:2398",
      "carrier_mode": "https"
    }
  ]
}
```

Или переключается через NYX Panel → `/self/tproxy` (кнопки HTTPS / Lanes / WS / WS Lanes).

Пос изменения режима tproxy-server перезапускается автоматически.

## Ссылки

- [Полный гайд](../../docs/TPROXY-GUIDE.md)
- [README.md](https://github.com/telegramdesktop/tproxy-server/blob/master/README.md)
- [PROTOCOL.md](https://github.com/telegramdesktop/tproxy-server/blob/master/PROTOCOL.md)
- [PLAN.md](https://github.com/telegramdesktop/tproxy-server/blob/master/PLAN.md)

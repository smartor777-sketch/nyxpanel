# Инцидент: `401 Unauthorized` на `/self/login` (dev)

**Дата:** 2026-11-05 / 2026-11-06
**Хост:** `203.0.113.21` (`dev.example.com`) — dev-стенд, на него указывает DNS `nyx.example.com`
**Статус:** исправлено

## Симптом

`GET https://nyx.example.com/self/login` возвращал:

```
HTTP/2 401
server: Caddy
www-authenticate: Basic realm="restricted"
content-length: 0
```

При этом Flask-панель на `127.0.0.1:5000` отдавала ту же страницу с `200`.

## Причина

На dev-хосте в `/etc/caddy/Caddyfile` внутри маршрута `/self*` был явно прописан `basicauth`:

```caddy
handle /self* {
    basicauth {
        admin $2a$14$...
    }
    reverse_proxy 127.0.0.1:5000
}
```

Именно он и генерировал `401` до обращения к панели.

Вторая, независимая проблема: `panel.service` был `disabled` и остановлен, поэтому на `:5000` никто не слушал. Без запуска сервиса даже после снятия `basicauth` был бы `502`.

### Почему это заняло время

DNS `nyx.example.com` указывает на `203.0.113.21`, но правки по ошибке вносились на другой стенд `203.0.113.23`
(`myserver-stend.example.com`). Его Caddyfile был при этом приведён к минимальному виду — конфиг восстановлен
из бэкапа (см. ниже).

## Что сделано

1. Бэкап конфига на dev:

   ```bash
   cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%Y%m%d-%H%M%S)
   # -> /etc/caddy/Caddyfile.bak.20261105-224137
   ```

2. Удалён **только** блок `basicauth` из `handle /self*`. Остальные маршруты и vhost'ы не тронуты.
3. Конфиг проверен и применён:

   ```bash
   caddy validate --config /etc/caddy/Caddyfile
   caddy fmt --overwrite /etc/caddy/Caddyfile
   systemctl reload caddy
   ```

4. Панель запущена и включена в автозапуск:

   ```bash
   systemctl enable --now panel.service
   ```

### Итоговый фрагмент Caddyfile

```caddy
handle /self* {
    reverse_proxy 127.0.0.1:5000
}
```

## Проверка

| Запрос | Результат |
|---|---|
| `https://nyx.example.com/self/login` | `200`, `<title>NYX Panel — Login</title>` |
| `https://nyx.example.com/self/` | `302` → `/self/login` |
| `https://nyx.example.com/` | `200` |
| `https://nyx.example.com/static/manifest.json` | `200` |
| `https://web.example.com/` | `200` |
| `http://nyx.example.com/self/login` | `308` → `https://…` |
| `https://nyx.example.com/self/api/v1/users` | `401` от Flask (Werkzeug, JSON) — штатная проверка сессии, не Basic-auth Caddy |

## Откат

```bash
cp -a /etc/caddy/Caddyfile.bak.20261105-224137 /etc/caddy/Caddyfile
systemctl reload caddy
# при необходимости вернуть прежнее поведение сервиса:
systemctl disable --now panel.service
```

## Второй стенд (`203.0.113.23`)

В ходе диагностики его Caddyfile был ошибочно заменён минимальным. Конфиг восстановлен из
`/etc/caddy/Caddyfile.pre-switch.20261004-190529` с актуализацией путей под текущий layout:

- upstream `127.0.0.1:5001` (было `:5000`);
- статика из `/opt/nyxpanel/panel` (каталога `/opt/proxy-panel` больше нет);
- сохранены vhost'ы `sleep-test`, `web`, `paste` и блок `forward_proxy`.

Бэкап состояния перед восстановлением: `/etc/caddy/Caddyfile.pre-restore.*`.
Caddy перезапущен, конфиг валиден, локально `/self/login` → `200`.

## Рекомендации

- Добавить внешний healthcheck на `https://nyx.example.com/self/login` (ожидаем `200` и HTML с
  `NYX Panel`), чтобы `basicauth`/упавший `panel.service` ловились сразу.
- `basicauth` перед панелью допустим только как осознанный staging-барьер. Если он нужен, логичнее
  выносить его на отдельный vhost (например, `admin.…`), а не на публичный `/self*`, где живёт
  страница логина.
- `panel.service` должен быть `enabled`; проверить, что после reboot панель поднимается.

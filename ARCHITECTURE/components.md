# Ключевые компоненты

## 1. Сервер (`server/`)

| Компонент | Описание |
|-----------|----------|
| `install.sh` | Auto-install скрипт: устанавливает полный стек на чистый Debian |
| `proxy_manager.sh` | Главный скрипт управления (v0.9). CLI + интерактивный режим. Управляет всеми протоколами. |

### proxy_manager.sh возможности

- `add_user <protocol> <username>` — добавить пользователя
- `del_user <protocol> <username>` — удалить пользователя
- `list_users [protocol]` — список пользователей
- `status` — статус всех сервисов
- Интерактивное меню при запуске без аргументов
- Генерирует конфиги, QR-коды, URI для каждого протокола

## 2. Прокси-протоколы

| Протокол | Порт | Сервис | Конфиг |
|----------|------|--------|--------|
| VLESS+XHTTP+REALITY | 4433 | Xray | `/usr/local/etc/xray/config.json` |
| Hysteria 2 | 30000 UDP | hysteria2 | `/etc/hysteria/config.json` |
| AmneziaWG | 39743 UDP | awg-quick@awg0 | `/etc/amnezia/amneziawg/awg0.conf` |
| NaiveProxy | 8443 | sing-box-naive | `/etc/sing-box/config.json` |
| Caddy forward_proxy | 443 | caddy | `/etc/caddy/Caddyfile` |
| Mieru | 444-448 | mita | `/etc/mita/server.json` |
| olcRTC | 39743 UDP | olcrtc | `/etc/olcrtc/users.json` |

### Архитектура Caddy + NaiveProxy

```
:443 ─ Caddy ─┬─ /panel/* /user/* /self/* → Flask :5000
              ├─ CONNECT (forward_proxy) → HTTPS tunnel
              └─ всё остальное → file_server (/var/www/html заглушка)

:8443 ─ sing-box ─ NaiveProxy inbound
:4433 ─ xray ─ VLESS+REALITY
```

Caddy собирается через `xcaddy` с модулем `github.com/caddyserver/forwardproxy`.
sing-box — готовый бинарник с GitHub Releases (не компилируется).

## 3. Панель (`panel/`)

Flask + Caddy reverse proxy.
- `panel/proxy-panel/app.py` — Flask приложение
- Порт: 5000 (localhost), доступен через Caddy `/panel*`, `/self*`, `/user*`
- `/samples/*` и `/static/*` — file_server напрямую из `/opt/proxy-panel/`
- Subscription endpoint: `/panel/api/v1/sub/{name}`
- Трафик: Xray (gRPC StatsService), Hy2 (trafficStats API), AWG (awg show)

## 4. olcbox (`android/olcbox/`)

Kotlin Multiplatform клиент:
- **Android:** VpnService + TUN + hev-socks5-tunnel (JNI C)
- **iOS:** SwiftUI + SwiftOlcRtcManager
- **Desktop:** JVM (macOS/Windows/Linux)
- **SharedUI:** Compose Multiplatform UI

## 5. olcRTC (`server/olcrtc-users/`)

Go-туннель на базе WebRTC:
- Маскируется под видеозвонки (Jitsi, Yandex Telemost, WB Stream)
- Транспорты: DataChannel, VP8Channel, SEIChannel, VideoChannel
- Шифрование: XChaCha20-Poly1305 + smux мультиплексирование
- Аутентификация: claims-based (user/pass из JSON-файла)
- Платформы: Linux, macOS, Windows, Android (gomobile)

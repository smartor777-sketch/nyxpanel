# Ключевые компоненты

## 1. Сервер (`server/`)

| Компонент | Описание |
|-----------|----------|
| `proxy_manager.sh` | Главный скрипт управления (v0.8). CLI + интерактивный режим. Управляет всеми протоколами. |
| `tmp_*.sh` | Экспериментальные/одноразовые скрипты для тестирования |
| `tmp_*.py` | Python-патчи для olcRTC и olcbox (claims auth) |

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
| VLESS+XHTTP+REALITY | 443 | Xray | `config/tmp_xray_v4.json` |
| Hysteria 2 | 30000 | hysteria-server | через proxy_manager.sh |
| AmneziaWG | 39743 UDP | awg | через proxy_manager.sh |
| NaiveProxy | 80 (Caddy) | Caddy | Caddyfile |
| Mieru | 444-448 | mieru | через proxy_manager.sh |
| olcRTC | 30001 WS | olcrtc | JSON users file |

## 3. Панель (`panel/`)

Flask + Caddy.
- `panel/proxy-panel.zip` — архив с исходниками
- Caddy reverse proxy на порт 8443 с basicauth
- Roadmap: 10 этапов развития (см. `docs/panel-roadmap.md`)

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

### Аутентификация (claims auth)

При патче добавлена аутентификация через JSON-файл:
```
// config/tmp_users.json
{"Katya":"katya_olc_2024","Merlin":"merlin_olc_2024","test":"test_olc_2024"}
```
- `Session.Config` получает поле `UsersFile`
- `createFileAuthHook()` читает файл и валидирует user/pass
- При несовпадении возвращает ошибку `USER_NOT_FOUND` / `PASSWORD_MISMATCH`

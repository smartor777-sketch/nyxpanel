# Детали протоколов

## VLESS + XHTTP + REALITY (порт 4433)

**Стек:** Xray-core
- REALITY — маскировка TLS handshake под реальный сайт (1.1.1.1)
- XHTTP — мультиплексированный HTTP транспорт
- Sniffing — автоматическое определение типа трафика
- gRPC StatsService API на 127.0.0.1:10085 для сбора трафика
- Управление: `proxy_manager.sh add_vless_user|del_user vless`

## Hysteria 2 (порт 30000 UDP)

**Стек:** QUIC-based (HTTP/3)
- Модифицирован на userpass auth (вместо единого пароля)
- OBFS саламандра
- TLS через Let's Encrypt (самоподписанный как fallback)
- Сбор трафика через trafficStats API (:30100)
- Управление: `proxy_manager.sh add_hy2_user|del_user hy2`

## AmneziaWG (порт 39743 UDP)

**Стек:** AmneziaWG — форк WireGuard с обфускацией
- Стандартный WireGuard handshake + дополнительная крипто-обфускация (Jc/Jmin/Jmax/S1-S4/H1-H4/Id)
- Клиент: AmneziaVPN приложение
- Управление: `proxy_manager.sh add_awg_user|del_user awg`
- Сбор трафика: `awg show` + pubkey map

## NaiveProxy (порт 8443)

**Стек:** sing-box (встроенный NaiveProxy inbound)
- NaiveProxy — клиент на Chromium-движке, добавляет случайный padding к HTTP CONNECT
- sing-box понимает Naive-модифицированный CONNECT
- TLS через Let's Encrypt сертификаты
- **Caddy forward_proxy НЕ используется для Naive** (Caddy шлёт обычный CONNECT, Naive-клиент ждёт padding)
- Управление: `proxy_manager.sh add_naive_user|del_user naive`
- Конфиг: `/etc/sing-box/config.json`

### Почему не Caddy forwardproxy?

Caddy `klzgrad/forwardproxy` с версии 2.8+ отправляет стандартный HTTP CONNECT без padding. Naive-клиент ожидает модифицированный CONNECT → connection reset. Sing-box имеет встроенный Naive inbound, корректно обрабатывающий Naive-трафик.

## Caddy forward_proxy (порт 443)

**Стек:** Caddy + `github.com/caddyserver/forwardproxy`
- Обычный HTTPS CONNECT proxy для браузеров и curl
- Basic Auth + probe_resistance (возвращает fake 404 для не-CONNECT запросов)
- Собирается через `xcaddy` (в стандартной сборке Caddy нет forwardproxy)
- Панельные маршруты: `/panel*`, `/user*`, `/self*` → Flask :5000
- Fallback: локальная HTML-заглушка `/var/www/html/index.html`

## Mieru (порты 444-448)

**Стек:** Собственный протокол на Go
- AES-GCM шифрование
- Фиксированные размеры пакетов
- 5 портов для распределения
- Управление: `proxy_manager.sh add_mieru_user|del_user mieru`
- Клиенты: NekoBox (ручной ввод, subscription не поддерживается)

## olcRTC

**Стек:** Go + WebRTC + Jitsi Meet
- Маскируется под видео-конференцию
- Транспорты: DataChannel (основной), VP8Channel (видео), SEIChannel (SEI в H264), VideoChannel
- Claims-based аутентификация через JSON-файл
- smux мультиплексирование TCP потоков
- XChaCha20-Poly1305 шифрование поверх WebRTC DTLS
- Порты: 39743 UDP (сервер), 30001 WS (отключён, зарезервирован)
- Управление: `proxy_manager.sh add_olcrtc_user|del_user olcrtc`

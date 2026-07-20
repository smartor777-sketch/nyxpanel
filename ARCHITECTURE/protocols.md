# Детали протоколов

## VLESS + XHTTP + REALITY (порт 443)

**Production конфиг:** `config/tmp_xray_v4.json`

REALITY — технология маскировки Xray под HTTPS:
- TLS handshake с реальным сайтом (www.microsoft.com)
- XHTTP — мультиплексированный HTTP транспорт (альтернатива TCP/gRPC/WebSocket)
- Sniffing — автоматическое определение типа трафика

**Клиентские конфиги:**
- `config/tmp_vless.json` — Sing-box формат
- `config/tmp_vless_simple.json` — упрощённый
- `config/tmp_xray_client.json` — Xray client (SOCKS → VLESS)
- `config/tmp_xray_client2.json` — альтернативный

**Экспериментальные варианты:**
- gRPC: `tmp_xray_grpc.json` — gRPC transport + REALITY
- Cloudflare: `tmp_xray_cf.json` — оптимизация под CF
- XHTTP: `tmp_xray_xhttp.json` — альтернативный XHTTP конфиг

## Hysteria 2 (порт 30000 UDP)

**Стек:** QUIC-based (HTTP/3), современный протокол
- Модифицирован на userpass auth (вместо единого пароля)
- Управление: `bash proxy_manager.sh add_hy2_user|del_hy2_user`

## AmneziaWG (порт 39743 UDP)

**Стек:** AmneziaWG — форк WireGuard с обфускацией
- Стандартный WireGuard handshake + дополнительная крипто-обфускация
- Клиент: AmneziaVPN приложение

## NaiveProxy (порт 80)

**Стек:** Caddy + forwardproxy
- Маскировка под обычный HTTPS трафик
- Простая настройка, низкая вероятность блокировки

## Mieru (порты 444-448)

**Стек:** Собственный протокол на Go
- AES-GCM шифрование
- Фиксированные размеры пакетов
- 5 портов для распределения

## olcRTC (порт 30001 WS)

**Стек:** Go + WebRTC + Jitsi Meet
- Маскируется под видео-конференцию
- Транспорты: DataChannel (основной), VP8Channel (видео), SEIChannel (SEI в H264), VideoChannel
- Claims-based аутентификация через JSON-файл
- smux мультиплексирование TCP потоков
- XChaCha20-Poly1305 шифрование поверх WebRTC DTLS

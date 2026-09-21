# Спецификация: NYX-Tunnel — анти-DPI прокси-протокол по рецепту Habr/tunnelcat

> Статус: черновик (v0.1)
> Цель: спроектировать **собственный прокси-протокол** по рецепту статьи «Что видит DPI»
> и открытой реализации tunnelcat-core: uTLS-маскировка, HTTP/2-транспорт на decoy-ручки,
> AEAD-фреймы, decoy-трафик и pacing. Не клон tunnelcat — свой wire format, усиленная
> криптография и встройка в nyxpanel.
>
> Основа: [docs/FORWARD_PROXY_GO_SPEC.md](FORWARD_PROXY_GO_SPEC.md) (паттерн документа),
> https://habr.com/ru/articles/1068156/ (анти-DPI рецепт),
> https://github.com/kostiakhait/tunnelcat-core (референс wire format, Apache-2.0).

---

## 1. Обзор

Прокси-протокол, у которого снаружи наблюдатель видит обычную HTTPS-сессию
браузера (HTTP/2 поверх TLS с браузероподобным ClientHello), а полезная нагрузка
идёт внутри зашифрованных фреймов. Построен на тех же пяти приёмах, что и статья:

1. **TLS-фингерпринт** — `uTLS`, ротация настоящих ClientHello (Chrome/Firefox/Edge/Safari).
2. **Транспорт-маскировка** — HTTP/2 POST на случайные «декор»-ручки вида `/api/media/upload`.
3. **Крипто фреймов** — `XChaCha20-Poly1305`, per-connection subkey (усиление к tunnelcat).
4. **Decoy-трафик** — фоновые настоящие запросы к реальным CDN.
5. **Pacing** — сглаживание всплесков потока во времени.

Плюс probe resistance (незнакомый запрос → скучный 404), многоузловость
с арбитром, подписывающим список узлов (Ed25519), и **H3/MASQUE** для UDP-пути.

```
TCP-путь (основной):
Браузероподобный ClientHello (uTLS)            внешне: HTTP/2 POST /api/media/upload
Клиент ──HTTPS(TLS 1.3, h2, uTLS)──► NYX-Tunnel сервер ──► целевой хост:порт
          XChaCha20-Poly1305 фреймы внутри

UDP-путь (H3/MASQUE):
Клиент ──QUIC/UDP──► NYX-Tunnel (MASQUE) ──UDP-датаграммы──► Netflix (QUIC)
          │                     │
          │ UDP-релей           │ NAT/MASQUERADE
          │ (не читает)        │
          └─────────────────────┘
```

## 2. Цели

- [ ] Логин по паролю → session token → защищённый data plane (как tunnelcat)
- [ ] Wire format: свой layout фреймов (не копия tunnelcat), `XChaCha20-Poly1305`
- [ ] Per-connection subkey через HKDF (форвард-секретность по флоу)
- [ ] Streaming-first транспорт (tag 0x01) + polling-fallback (tag 0x00)
- [ ] uTLS ClientHello ротация между соединениями
- [ ] Pacing и decoy-трафик (включаются/выключаются конфигом)
- [ ] Probe resistance: незнакомый запрос → 404
- [ ] SOCKS5 TCP + UDP ASSOCIATE на клиенте
- [ ] **H3/MASQUE** — UDP-релей до конечных сайтов (RFC 9298/9484)
- [ ] **Адаптивный выбор** TCP/UDP пути (автоматический фолбэк)
- [ ] Режим белых списков: SNI-impersonation + probe-forwarding (REALITY-style) — §15.5
- [ ] Арбитр-подписанный манифест узлов + пул диалеров с failover
- [ ] Интеграция с панелью: `add_nytun_user`, `remove_protocol`, коллектор

## 3. Не входит в scope (non-goals)

- Reverse proxy, терминация TLS с MITM — не делаем
- Свой GUI-клиент — только CLI (SOCKS5) + gomobile-обвязка для Android (позже)
- Поддержка в sing-box/браузере «из коробки» — свой транспорт, свои клиенты
- Децентрализованный DHT — Kademlia-обнаружение опционально (этап 4), MVP — статический манифест

---

## 4. Логин

`POST /` с `Content-Type: application/json`.

```json
{".command": "verifyPassword", "path": "users", "user": "<username>", "password": "<password>", "key": "<apikey>"}
```

Опционально: `key_id`, `device_id`, `device_name`.

**Ответ** (HTTP 200):

```json
{"session": "<opaque token>"}
```

- `session` — 32 случайных байта, hex. Сервер хранит `session → (user, expires_at, bytes_counter)`.
- Любой другой статус, или 200 без `session` → `ErrAuthRejected`.
- Rate-limit по IP на логин (против brute force), сравнение пароля с постоянным временем.

## 5. Ключевой материал

В отличие от tunnelcat (где ключ фрейма = `BLAKE2b-256(session)` на всю сессию):

- `K_master = HKDF-SHA256(ikm = session_token, salt = "", info = "nytun/v1/master")` → 32B
- `K_conn = HKDF-SHA256(ikm = K_master, salt = conn_id, info = "nytun/v1/conn")` → 32B

**Свойства:**
- Compromise одного флоу (утечка `K_conn`) не вскрывает сессию и другие флоу.
- `conn_id` — 16 случайных байт, генерится клиентом, уникален на флоу.
- Шифр: **XChaCha20-Poly1305** с **случайным 24B nonce** на фрейм — без счётчика
  и риска коллизии nonce (у tunnelcat 12B случайный nonce — коллизии возможны на объёме).

**Фрейм:**

```
[24B nonce][XChaCha20-Poly1305(plaintext) + 16B tag]
```

## 6. Data plane — HTTP-транспорт

Каждый запрос — `POST` на **случайную** ручку из пула decoy-путей (свои, не tunnelcat):

- `/api/media/upload`
- `/api/media/chunk`
- `/api/content/submit`
- `/api/analytics/batch`
- `/api/telemetry/push`

Заголовки маскируются под настоящий upload: `Content-Type: application/octet-stream`,
`Accept: application/json`, `User-Agent`, совпадающий с семейством фингерпринта, `Cache-Control: no-cache`.

Сессия передаётся заголовком `X-Session` (как в tunnelcat). **Известный слабый сигнал** —
константный заголовок, см. §15 (открытый вопрос).

Тело запроса/ответа — зашифрованный фрейм §5.

## 7. Фреймы данных

Два режима. **Streaming — основной**, polling — fallback.

### 7.1 Streaming (tag 0x01) — основной

Плоский текст (до шифрования):

```
[1B 0x01][16B conn_id]
```

Клиент открывает `POST`, сервер отвечает `200` + **chunked/streamed** зашифрованное тело.
Дальше данные идут в обе стороны как вложенные фреймы (внутри того же потока):

```
[1B type][16B conn_id][4B seq_be][payload]
```

| type | Название | payload | Кто шлёт |
|------|----------|---------|----------|
| 0x01 | open | `target` (host:port), seq=0 | клиент |
| 0x02 | data | байты целевого соединения | оба |
| 0x03 | close | пусто | оба |
| 0x04 | ping/keepalive | пусто | оба |

`seq` монотонно растёт — детект потери/дублирования фреймов.

### 7.2 Polling (tag 0x00) — fallback

Когда streaming невозможен (HTTP/1.1-посредник, корпоративный прокси):

Запрос:
```
[1B 0x00][16B conn_id][4B seq_be][2B target_len_be][target][payload]
```
- `seq == 0` → сервер свежим дозванивается на `target`.
- `seq > 0` → дозапись в существующее соединение.
- Пустой `payload` = keep-alive poll.

Ответ (паддинг до ≥512 байт):
```
[4B data_len_be][data][random padding]
```
Сервер держит короткое окно чтения (~200 мс), как `core.BuildUploadResponse`.

---

## 8. Pacing

- Token-bucket на соединение: `rate` и `burst` из конфига.
- Буферизованный writer доливает в сокет с заданной скоростью — гасит всплески
  и временной рисунок туннеля.
- Не трогает криптографию, только форму потока во времени.

## 9. Decoy-трафик

- Фоновые HTTP/2-потоки к реальным CDN (cloudflare.com, google.com, akamai.com —
  список из конфига), с реалистичными заголовками и чанк-аплоадом.
- Запросы настоящие: TLS, шифрование, обработка → **заметный CPU** (компромисс из статьи).
- По умолчанию `enabled: false`, включается для критичных пользователей.

## 10. Probe resistance

- `GET /`, `/favicon.ico`, любой незнакомый метод/путь → **404** со скучной HTML-страницей
  («такого ресурса здесь нет»), без признаков протокола.
- Ответ не подтверждает назначение сервера при active probing.
- `POST /` отвечает 200 только на валидную форму логина с верными кредами.

## 11. Многоузловость

- **Арбитр** подписывает манифест узлов (control/exit) приватным ключом Ed25519.
- Клиент получает манифест, проверяет `VerifySignedPayload(payload, pubkey, sig)` (Ed25519)
  и только потом доверяет узлам.
- **Пул диалеров** (идеи из tunnelcat `dialer_pool.go`):
  - RTT-скоринг узлов, выбор по надёжности (взвешенный), трекинг живости;
  - failover: узел деградировал → переключение без обрыва сессии.
- MVP: статический манифест в конфиге; Kademlia-DHT — опционально (этап 4).

## 12. SOCKS5 на клиенте

- TCP CONNECT (RFC 1928 §4) → флоу через туннель.
- UDP ASSOCIATE (§7) → UDP-relay (позже, этап 3).
- Лимит соединений на IP (против abuse), bypass-менеджер для LAN/локальных маршрутов
  (прямой роутинг, как в tunnelcat `socks5.go`).

---

## 13. Конфигурация (YAML)

### 13.1 Сервер — `/etc/nytunnel/config.yaml`

```yaml
listen:
  addr: ":443"
  tls:
    cert: "/etc/proxy-certs/fullchain.pem"
    key: "/etc/proxy-certs/privkey.pem"
    alpn: ["h2", "http/1.1"]        # uTLS-клиент обязан совпадать с h2

users:
  - username: "admin"
    password: "nyxprod"             # plaintext или bcrypt "$2a$..."

transport:
  streaming: true                   # false → только polling
  polling: true                     # fallback
  decoy_paths: ["/api/media/upload", "/api/media/chunk", "/api/content/submit", "/api/analytics/batch", "/api/telemetry/push"]

whitelist_mode:                     # §15.5 — работа под белыми списками операторов
  enabled: false
  sni_impersonate: "userapi.com"    # белый домен в TLS ClientHello (из §15.5 списка)
  probe_forward: true               # чужие пробы → реальный белый сайт (REALITY-style)
  forward_dial_timeout: 2s

arbiter:
  pubkey: ""                        # hex Ed25519, для проверки манифестов
  manifest_url: ""                  # опционально

pacing:
  rate_bytes_per_s: 0               # 0 = выкл
  burst_bytes: 131072

probe_resistance:
  enabled: true
  landing_html: ""

metrics:
  enabled: true
  addr: "127.0.0.1:9101"
  path: "/metrics"
```

### 13.2 Клиент — `/etc/nytunnel/client.yaml` (или аргументы CLI)

```yaml
server: "https://node.example.com"
login: {user: "...", password: "..."}
socks: "127.0.0.1:1080"             # локальный SOCKS5
tun: false                          # TUN-режим (этап 5)

whitelist_mode:                     # §15.5 — SNI белого домена поверх TLS
  enabled: false
  sni: "userapi.com"                # должен совпадать с server-side sni_impersonate

fingerprints: ["chrome", "firefox", "edge", "safari"]  # ротация uTLS
decoy:
  enabled: false
  hosts: ["cloudflare.com", "google.com"]
pacing:
  rate_bytes_per_s: 0
```

## 14. Безопасность

- **No DNS leak:** резолвы только через конфигурируемый DoH (или системный).
- Пароли не логируются; сравнение с постоянным временем; rate-limit логина по IP.
- Таймауты: dial, TLS-handshake (1с), idle, заголовки (защита от slowloris).
- Сессия: expiry + ротация токена; per-connection subkey (форвард-секретность).
- Лог без тел запросов, кук, паролей.

## 15. Риски и открытые вопросы

- **`X-Session` — константный заголовок** — сам по себе слабый классификационный сигнал.
  Открытый вопрос: перенести токен внутрь фрейма с envelope-ключом (сложнее) или оставить
  заголовок для MVP (проще, как tunnelcat).
- **uTLS-фингерпринт недостаточен сам по себе:** после браузероподобного ClientHello сервер
  должен вести себя как реальный сайт — TLS 1.3, ALPN `h2`, HTTP/2 settings, совпадающие с
  браузерами. Разъезд ClientHello и поведения сервера = сигнал для DPI (то самое из статьи).
- **Валидность у конкретных провайдеров проверяется только в поле** — как и в статье,
  лабораторного бенчмарка нет.
- **Decoy-трафик дорогой по CPU** — по умолчанию выключен.
- **Клиент для пользователей:** sing-box не понимает этот транспорт. Нужен свой клиент
  (CLI SOCKS5 → gomobile для OlcboxME, этап 6).
- **HTTP/2 через uTLS на Go** — нужно аккуратно собрать `http2.Transport` поверх
  `utls.UClient`, проверить совместимость с сервером на `h2`.
- Открытый вопрос: нужен ли **UDP-relay (CONNECT-UDP/MASQUE)** в этом протоколе, или
  достаточно SOCKS5 TCP — решает интеграция с L1-путём из FORWARD_PROXY_GO_SPEC.

### 15.5 Белые списки мобильных операторов (полевая реальность РФ)

**Что произошло (сент 2025).** Минцифры запустило пилот «белых списков» на сетях МТС, T2,
Билайн, Мегафон, Ростелеком: в периоды ограничений мобильного интернета доступны только
Госуслуги, VK/OK/Mail.ru/Max, сервисы Яндекса, Ozon/Wildberries, Avito/Дзен/Rutube, платёжная
система «Мир», сайты правительства, ДЭГ и личные кабинеты операторов.

**Принципиально важно:** белый список фильтрует по **адресу назначения (IP/домен/SNI)**, а не по
содержимому пакетов. В этом режиме **обфускация не помогает** — решает только то, к какому
адресу идёт соединение. Вся маскировка §1–§10 здесь вторична; первичен адрес.

**Как обходят сейчас (по опубликованным гайдам):**
1. **SNI-impersonation (REALITY-style).** Свой сервер (IP любой, часто зарубежный), в TLS
   ClientHello — SNI **белого домена** (`userapi.com`, `mds.yandex.net`, `ozone.ru`,
   `wildberries.ru`, `online.sberbank.ru`, `tinkoff`, `mts.ru`, `beeline.ru`, `t2.ru`,
   `rutube`, `kinopoisk`, `avito`, `2gis` — опубликованы списки ~100 доменов). Неавторизованный
   проб → сервер **пересылает на реальный белый сайт** (выглядит как обычный браузинг);
   авторизованный клиент → туннель.
2. **CDN-fronting.** Клиент подключается к IP Cloudflare/белого CDN (они в белом списке, т.к.
   за ними стоят легальные сервисы), SNI = белый домен; origin скрыт за CDN.
3. **RU-локации хостинга.** В гайдах рекомендуют российские локации (aeza.net/.ru) как более
   стабильные для обхода.

**«Белый IP» отдельно не покупается.** Белым является **домен/SNI, который ты impersonate**,
а не серверный IP. Решение = доступный сервер + правильный SNI + probe-forwarding.

**Следствие для NYX-Tunnel:** для работы в whitelist-режиме нужен **SNI-impersonation +
probe-forwarding** (REALITY-подобная логика на сервере). Наша uTLS-маскировка уже даёт
браузероподобный ClientHello — остаётся добавить конфигурируемый SNI (§13) и форвард чужих
проб на реальный белый сайт. Это **критерий готовности этапа 1**: проверка у реального
оператора в whitelist-режиме с белым SNI.

---

## 16. Интеграция с панелью

- **Бинарь:** `/usr/local/bin/nytunneld`
- **Конфиг:** `/etc/nytunnel/config.yaml`
- **Unit:** `/etc/systemd/system/nytunnel.service` — по образцу hardened-юнита olcrtc
  (не-root пользователь, `NoNewPrivileges`, `PrivateTmp`, абсолютные пути данных):

```ini
[Unit]
Description=NYX-Tunnel (anti-DPI proxy)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/nytunneld -c /etc/nytunnel/config.yaml
Restart=always
RestartSec=3
User=nytunnel
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

- **`proxy_manager.sh`** (паттерн `add_naive_user` / `remove_protocol`):
  - `add_nytun_user()`: `openssl rand -hex 12` пароль → `jq` в `/etc/nytunnel/config.yaml` →
    `systemctl restart nytunnel` → конфиг `$BASE_DIR/$username/${username}_nytun.json` + QR;
  - `remove_protocol()`: добавить `nytun` в case `|hy2|awg|naive|mieru|olcrtc|vless|nytun|`,
    проверка `[ -f "$BASE_DIR/$username/${username}_nytun.json" ]`;
  - `del_user()`: чистка конфига и файлов пользователя.
- **Коллектор:** access-лог JSON (ts, client, user, bytes) или метрика `nytun_user_bytes`
  → парсинг в БД, как у остальных протоколов.

## 17. Этапы разработки

| Этап | Содержание | Критерий готовности |
|------|-----------|---------------------|
| **1. MVP wire** | Логин, XChaCha-фреймы, HTTP/2 через uTLS, polling, SOCKS5 TCP, probe resistance, SNI-impersonation + probe-forwarding (whitelist_mode) | Go-тесты + **полевой тест у оператора в whitelist-режиме** |
| **2. Streaming + UDP** | Streaming-first (0x01), keepalive/close, UDP ASSOCIATE | UDP-трафик через туннель работает |
| **3. Pacing + decoy** | Token-bucket pacing, decoy-потоки к CDN, ротация фингерпринтов | форма потока сглажена, фингерпринты меняются |
| **4. Многоузловость** | Арбитр-манифест (Ed25519), пул диалеров с failover, RTT-скоринг | failover между узлами без обрыва |
| **5. TUN** | tun2socks + Wintun (Windows), `-tun` режим | TUN-интерфейс поднимается, трафик идёт |
| **6. Панель + прод** | `add_nytun_user`, коллектор, Android-клиент (gomobile), доки | юзер добавляется из меню, статистика в БД |

**Итого:** MVP (этап 1) ~1 неделя; полный объём 1–3 этапов ~2 недели.

## 18. Зависимости (Go)

| Библиотека | Назначение |
|-----------|-----------|
| `github.com/refraction-networking/utls` | браузерные ClientHello, ротация |
| `golang.org/x/crypto` | chacha20poly1305 (XChaCha), hkdf, blake2b |
| `net/http` + `golang.org/x/net/http2` | HTTP/2 транспорт |
| `golang.org/x/crypto/bcrypt` | пароли |
| `github.com/prometheus/client_golang` | метрики |
| `gopkg.in/yaml.v3` | конфиг |
| `xjasonlyu/tun2socks`, Wintun | TUN (этап 5, опционально) |

## 19. Улучшения на основе qeli

> Источник: [litvinovtd/qeli](https://github.com/litvinovtd/qeli) (AGPL-3.0)
> Бенчмарки: [отчёт 0.8.0](docs/eng/reports/benchmarks/vpn_protocol_benchmark_repeat_2026-09-01.md)
> Средний throughput: **1220 Мбит/с** (TCP, 4 потока), топ-5 профилей: **1767 Мбит/с**

### 19.1. Reality TLS 1.3 вместо uTLS-маскировки

**Проблема текущего NYX-Tunnel:** uTLS даёт браузероподобный ClientHello, но поведение
сервера (HTTP/2 settings, ALPN, response timing) может не совпадать с браузером → DPI детект.

**Решение qeli (reality-tls):** Настоящий TLS 1.3 с proxy-подделкой (как в Xray/VLESS REALITY):
- Сервер терминирует **настоящий** TLS 1.3 (не fake)
- ClientHello содержит SNI белого домена (`www.microsoft.com`)
- Сервер проксирует handshake на реальный target (peek-and-decide)
- Авторизованный клиент → туннель; неавторизованный → реальный сайт

**Интеграция в NYX-Tunnel:**
```
Клиент ──HTTPS(TLS 1.3, h2, SNI=www.microsoft.com)──► NYX-Tunnel
          │                                              │
          │ peek SNI + проверка авторизации               │
          │                                              ├── авторизован → туннель
          │                                              └── нет → proxy на microsoft.com
          └── XChaCha20-Poly1305 фреймы внутри
```

**Преимущества:**
- Настоящий TLS 1.3 (не маскировка, а реальный протокол)
- Anti-active-probing: сервер выглядит как реальный сайт
- Нетsignature-based DPI детекта (в отличие от uTLS)

### 19.2. Post-quantum handshake (ML-KEM-768)

**Проблема:** Квантовые компьютеры могут взломать X25519/ECDH в будущем.

**Решение qeli:** Гибридный ключевой обмен:
```
K_shared = X25519(server_pub, client_priv) || ML-KEM-768(ciphertext, shared_secret)
```

**Интеграция в NYX-Tunnel:**
- Добавить ML-KEM-768 в handshake (POST /login)
- K_master = HKDF(SHA256, ikm = K_shared, ...)
- Обратно совместимо: клиент без PQ отправляет только X25519

### 19.3. Traffic shaping (Poisson idle cover)

**Проблема:** Периодический heartbeat (~15 сек) — fingerprints для DPI.

**Решение qeli:**
- Заменить heartbeat на **случайные idle-записи** (Poisson distribution)
- Средний gap: 700мс, min: 40мс, max: 6000мс
- Бюджет: 16384 байт/сек
- **Нулевая добавочная задержка** (реальные пакеты не задерживаются)

**Интеграция в NYX-Tunnel:**
```yaml
transport:
  traffic_shaping:
    enabled: true
    idle_gap_mean_ms: 700
    idle_gap_min_ms: 40
    idle_gap_max_ms: 6000
    budget_bytes_per_sec: 16384
```

### 19.4. Recordizer (маскировка пакетов)

**Проблема:** Размер пакета — сигнал для DPI (1 пакет = 1 запись).

**Решение qeli:**
- Recordizer: **обязательный** padding каждого пакета до фиксированных размеров
- Режимы: `required` (все пакеты), `optional` (только idle), `disabled`
- Устраняет корреляцию "1 пакет = 1 команда"

**Интеграция в NYX-Tunnel:**
```yaml
transport:
  recordizer:
    enabled: true
    mode: required  # или optional
```

### 19.5. Session roaming

**Проблема:** Смена Wi-Fi/LTE → разрыв VPN → переподключение.

**Решение qeli:**
- Клиент переносит DTLS-сессию между сетями
- Сервер отслеживает по session ID
- **Нулевой даунтайм** при смене IP

**Интеграция в NYX-Tunnel:**
- Добавить session ID в заголовок `X-Session`
- Сервер кэширует сессию по ID (TTL = 30 мин)
- Клиент отправляет тот же ID при переподключении

### 19.6. Multiple wire modes

**Проблема:** Разные провайдеры блокируют по-разному; нужен выбор.

**Решение qeli:** 6 режимов:
| Режим | Описание | Когда использовать |
|-------|----------|-------------------|
| `plain` | Без маскировки | Тестирование |
| `fake-tls` | TLS 1.3 mimicry | Пассивный DPI |
| `obfs` | ChaCha20 + WebSocket | Активный DPI |
| `reality` | REALITY (peek-and-decide) | Активный DPI + probing |
| `reality-tls` | REALITY TLS 1.3 + HTTP/2 | Флагман |
| `udp-quic` | QUIC-shaped UDP | Когда TCP:443 режется |

**Интеграция в NYX-Tunnel:**
- Реализовать 3 ключевых режима: `nytun-reality-tls`, `nytun-obfs`, `nytun-udp`
- Клиент выбирает по ссылке `nytun://...?mode=reality-tls`

### 19.7. Per-app routing

**Проблема:** Полный туннель → всё идёт через VPN (включая локальные сервисы).

**Решение qeli:**
- Клиент указывает包 exclude/include (Android/Windows/macOS)
- Full-tunnel по умолчанию, опциональный split-tunnel

**Интеграция в NYX-Tunnel:**
- Добавить в конфиг клиента:
```yaml
routing:
  mode: full  # или split
  include: ["com.app1", "com.app2"]  # только эти приложения
  exclude: ["com.local"]             # кроме этих
```

### 19.8. IPv6 first-class

**Проблема:** Многие VPN-протоколы поддерживают IPv6 частично.

**Решение qeli:**
- Нативный dual-stack IPv4/IPv6
- TUN-интерфейс с IPv6
- DNS через DoH/DoT

**Интеграция в NYX-Tunnel:**
- Поддержка IPv6 в TUN-режиме
- DNS-резолвер через DoH

### 19.9. H3/MASQUE (UDP-релей)

**Проблема:** TCP:443 может быть заблокирован/троттлирован провайдером. QUIC до
конечных сайтов (Netflix, YouTube) недоступен напрямую.

**Решение (из FORWARD_PROXY_GO_SPEC.md §5.4):**
- **H3/MASQUE** (RFC 9298/9484): клиент устанавливает QUIC-соединение до прокси,
  прокси **релеит UDP-датаграммы** до целевого сайта (не терминит TLS, не читает трафик)
- Клиент сам ведёт QUIC до Netflix; прокси — просто UDP-мост

**Архитектура:**

```
Клиент ──QUIC/UDP──► NYX-Tunnel (MASQUE) ──UDP-датаграммы──► Netflix (QUIC)
          │                     │
          │ UDP-релей           │ NAT/MASQUERADE
          │ (не читает)        │
          └─────────────────────┘
```

**Преимущества:**
- **E2E шифрование:** прокси не видит трафик (только релеит)
- **QUIC до сайтов:** клиент получает HTTP/3 от Netflix/YouTube
- **Обход TCP-блокировок:** UDP-транспорт не fingerprint'ится как VPN
- **Низкая задержка:** без терминации TLS на прокси

**Интеграция в NYX-Tunnel:**

```yaml
# Конфиг сервера
transport:
  masque:
    enabled: true
    listen: ":8443"  # UDP-порт для MASQUE
    # или TCP:443 с WebSocket fronting

# Конфиг клиента
upstream:
  mode: masque  # или h3-relay
  server: "nyx.example.com:8443"
```

**Режимы работы:**

| Режим | Транспорт | Когда использовать |
|-------|-----------|-------------------|
| `nytun-tcp` | HTTP/2 POST (текущий) | TCP:443 работает |
| `nytun-masque` | UDP-релей (H3/MASQUE) | TCP:443 режется, UDP работает |
| `nytun-hybrid` | Авто-выбор TCP/UDP | Адаптивный (L1→L2→L3) |

**Интеграция с адаптивным селектором (§15 FORWARD_PROXY_GO_SPEC.md):**
- Клиент пробует MASQUE (L1) → если UDP мёртв → TCP (L2/L3)
- Сервер отвечает на `/status` с текущим состоянием UDP

---

### Сводная таблица: NYX-Tunnel (текущий) vs NYX-Tunnel (с qeli-улучшениями)

| Компонент | Текущий NYX-Tunnel | + qeli улучшения |
|-----------|-------------------|------------------|
| TLS | uTLS (маскировка) | **Reality TLS 1.3** (настоящий) |
| Handshake | HKDF-SHA256 | **+ ML-KEM-768** (post-quantum) |
| Traffic shaping | Token-bucket pacing | **Poisson idle cover** (0 задержка) |
| Padding | Нет | **Recordizer** (маскировка размеров) |
| Roaming | Нет | **Session roaming** (без разрыва) |
| Wire modes | 1 (HTTP/2) | **7 режимов** (reality-tls, obfs, udp, masque) |
| Routing | Full-tunnel | **Per-app routing** (split-tunnel) |
| IPv6 | Частичный | **Нативный dual-stack** |
| UDP-путь | Нет | **H3/MASQUE** (UDP-релей до сайтов) |

### Рекомендация

**Взять от qeli:**
1. ✅ Reality TLS 1.3 (anti-active-probing)
2. ✅ Post-quantum handshake (ML-KEM-768)
3. ✅ Traffic shaping (Poisson idle cover)
4. ✅ Recordizer (маскировка размеров)
5. ✅ Session roaming
6. ✅ Multiple wire modes

**Взять из FORWARD_PROXY_GO_SPEC.md:**
7. ✅ H3/MASQUE (UDP-релей до конечных сайтов)

**Оставить от NYX-Tunnel:**
1. ✅ XChaCha20-Poly1305 (усиление к tunnelcat)
2. ✅ Per-connection subkey (форвард-секретность)
3. ✅ Decoy-трафик (фоновые запросы к CDN)
4. ✅ Probe resistance (404 на незнакомые запросы)
5. ✅ Многоузловость (арбитр + failover)

**Итого:** NYX-Tunnel с qeli + MASQUE = **полный стек для обхода DPI**:
- TCP-путь (Reality TLS 1.3)
- UDP-путь (H3/MASQUE)
- Адаптивный выбор между ними

---

## 20. Итог

- Рецепт из статьи раскладывается на 5 независимых слоёв; все применимы в nyxpanel.
- **Усиления к tunnelcat:** XChaCha20-Poly1305 + случайный 24B nonce, per-connection HKDF
  subkey, свои decoy-ручки, streaming-first с poll-fallback, pacing.
- **Улучшения от qeli:** Reality TLS 1.3, post-quantum handshake, traffic shaping,
  recordizer, session roaming, multiple wire modes.
- MVP прост: один Go-бинарник, конфиг, systemd, `add_nytun_user` — вписывается в текущие
  паттерны панели (naive/olcrtc уже по этой схеме).
- Ключевой риск — не в коде, а в полевой проверке (как и у автора статьи): поведение
  у реальных провайдеров.
- **Лицензия:** qeli — AGPL-3.0; использование идей допустимо с указанием источника.

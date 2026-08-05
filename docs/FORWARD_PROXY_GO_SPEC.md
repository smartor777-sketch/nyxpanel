# Спецификация: адаптивный форвард-прокси на Go (QUIC/MASQUE + HTTP/3 на последней миле)

> Статус: черновик (v0.2)
> Цель: выстроить **адаптивный транспортный селектор** — систему, которая в зависимости от
> поведения интернет-провайдера автоматически выбирает лучший путь до целевого сайта
> (Netflix, YouTube и т.д.): от нативного QUIC-туннеля до TCP-прокси с фолбэками.
>
> Ключевое уточнение относительно v0.1: «QUIC до Netflix» достигается **двумя разными механизмами**,
> и именно их комбинация + авто-выбор и есть продукт (см. §1, §15).

---

## 1. Обзор

Есть два способа получить QUIC до целевого сайта, и они принципиально разные:

**Механизм A — UDP-релей / CONNECT-UDP (MASQUE, RFC 9298/9484).** Это «QUIC до Netflix».
Клиент сам устанавливает QUIC-соединение до Netflix, а прокси только **перенаправляет
UDP-датаграммы** (не читает, не терминит). Netflix отдаёт контент по HTTP/3 клиенту напрямую,
просто туннелем через сервер. Работает только если **UDP между клиентом и сервером не блокируется**.

```
Браузер/клиент ──QUIC до Netflix──► прокси (UDP-relay) ──UDP-датаграммы──► Netflix
```

**Механизм B — прокси как HTTP/3-клиент (последняя миля).** Прокси **сам** ходит на сайт
по HTTP/3 (quic-go `http3.Transport`). Работает только для `http://`-трафика. К HTTPS-сайтам
(CONNECT-туннели) неприменимо без MITM. Это «запасной» путь, когда UDP-релей недоступен.

```
Клиент ──(TCP, CONNECT)──► Go-прокси ──HTTP/3/QUIC──► целевой сайт (http://)
```

**Проблема, которую решает система:** провайдер может блокировать/троттлить:
- UDP целиком или UDP:443 (тогда Механизм A мёртв) → нужен B;
- h3-клиент к сайту (нет такого) → нужен чистый TCP;
- и даже TCP-прокси могут деградировать по времени суток/протоколу.

Поэтому строим **лестницу путей L1–L3** и автоматический переключатель между ними.

---

## 2. Цели

- [ ] Прокси работает как стандартный HTTP forward proxy: `curl -x http://user:pass@host:8443 http://...`
- [ ] **Механизм A:** поддержка UDP-релея (CONNECT-UDP / MASQUE) для QUIC-туннелей до целевых сайтов
- [ ] **Механизм B:** проксирование `http://`-запросов на целевую сторону **по HTTP/3**, если сайт поддерживает h3
- [ ] **Фолбэк:** QUIC/UDP не работает → автоматический переход на TCP (HTTP/1.1/HTTP/2)
- [ ] **Адаптивный выбор пути (L1–L3)** на основе пробинга сети (§15)
- [ ] Поддержка `CONNECT` для HTTPS-сайтов (сырой TCP-туннель) как крайний путь
- [ ] Basic-auth на входящей стороне (совместимость с текущим конфигом)
- [ ] Поведение как у Caddy forward_proxy: `hide_ip`, `hide_via`, `probe_resistance`
- [ ] systemd, метрики, access-лог с указанием использованного пути (L1/L2/L3 + transport)

## 3. Не входит в scope (non-goals)

- Reverse proxy / балансировка — не делаем
- Терминация TLS с MITM-перешифрованием HTTPS-туннелей — **не делаем** (нарушает E2E)
- Разработка собственного клиентского приложения — клиентом является sing-box/бранзер, ATS-логика на сервере + конфиг клиента (§16)

---

## 4. Входящая сторона (клиент → прокси)

### 4.1. Листенер

- HTTPS-listener `:8443` (освобождается после вывода Caddy/sing-box naive).
- TLS: переиспользовать `/etc/proxy-certs/fullchain.pem` + `privkey.pem`.
- ALPN на ребре: `h2, http/1.1`; опционально `h3` (входящий QUIC).
- Методы:
  - `CONNECT host:port` → TCP-туннель (путь L3), `200 Connection established`.
  - `CONNECT-UDP` (MASQUE) → UDP-релей (путь L1), см. §5.4.
  - `GET http://host/...` → проксирование (пути L2/L3), см. §5.
  - `GET /` (без URL) → probe-страница (§4.4).

### 4.2. Аутентификация

- HTTP Basic auth из файла конфига.
- Форматы пароля: **plaintext** (`user: pass`) и **bcrypt** (`user: $2a$...`) — совместимость с Caddy.
- Сравнение с постоянным временем (`crypto/subtle`), rate-limit по IP (опц.).
- Интеграция с пользователями `proxy_manager.sh` (§11).

### 4.3. `hide_ip` / `hide_via`

- Не добавлять `X-Forwarded-For`, `X-Real-IP`, `Via` при проксировании.
- Стирать входящие `X-Forwarded-For` / `Via` перед отправкой на цель.

### 4.4. `probe_resistance`

- `GET /`, `/favicon.ico` без прокси-намерения → нейтральный HTML (200), а не признак прокси.
- `CONNECT`/`CONNECT-UDP` без auth → `407 Proxy Authentication Required`.
- Повторяет поведение Caddy `forward_proxy { probe_resistance }`.

---

## 5. Исходящая сторона (прокси → сайт)

### 5.1. Три пути (лестница)

| Путь | Транспорт до сайта | Когда используется |
|------|--------------------|--------------------|
| **L1** | QUIC-релей (UDP-датаграммы до цели, MASQUE/CONNECT-UDP) | UDP клиент→сервер работает; сайт поддерживает h3/QUIC |
| **L2** | HTTP/3-клиент (прокси сам ходит по QUIC, для `http://`) | UDP-релей недоступен, но сайт поддерживает h3 |
| **L3** | TCP (HTTP/1.1/HTTP/2 или CONNECT-туннель) | Всё остальное; HTTPS-сайты; крайний случай |

Выбор пути — §15 (адаптивный селектор).

### 5.2. Проксирование `http://`-запросов (L2/L3)

- Собрать целевой URL из request-line (или `Host` + absolute-form).
- **L2:** `http3.Transport` (quic-go) как `http.RoundTripper`.
- **L3:** `http.Transport` (HTTP/1.1 + HTTP/2 по ALPN).
- Перенести: метод, путь+query, заголовки, тело, trailers. Ответ цели → клиенту как есть.

### 5.3. CONNECT-туннели (HTTPS-сайты, L3)

- `CONNECT netflix.com:443` → **всегда TCP**. HTTP/3 неприменим к сырому байтовому туннелю.
- `io.Copy` в обе стороны. В access-логе: `transport: tcp(tunnel)`.

### 5.4. CONNECT-UDP / MASQUE (L1)

- Поддержка `CONNECT-UDP` (RFC 9298) и/или MASQUE (RFC 9484): клиент отправляет QUIC-датаграммы
  цели внутри QUIC-соединения до прокси; прокси релеит их как обычные UDP-пакеты.
- Это **ключевой механизм «QUIC до Netflix»**: браузер/клиент сам ведёт QUIC до Netflix,
  прокси не терминит TLS и не читает трафик.
- Реализация на Go: библиотеки `github.com/quic-go/quic-go` (MASQUE-ext), `github.com/bifurcation/mint` (нет),
  реально — `github.com/cloudflare/cirrus`/`go-masque` или собственная обвязка поверх quic-go.
  Альтернатива: **не писать самим**, а использовать sing-box (см. §16) с уже готовым CONNECT-UDP.

---

## 6. Обнаружение поддержки h3 у сайта (для пути L2)

### 6.1. HTTPS DNS record (SVCB, тип 65)

- Запрос `HTTPS <domain>`; если `alpn="h3"` → сайт поддерживает h3.
- Резолвить через DoH (Cloudflare/Google) или системный резолвер. Кэш с TTL (1ч).

### 6.2. Alt-Svc

- Из HTTP-ответов по TCP-пути кэшировать `Alt-Svc: h3=":port"; ma=seconds`.
- `host → (h3, порт, до_времени)`, при повторных запросах сразу пробовать QUIC.

### 6.3. Пробный QUIC-хендшейк

- Dial UDP `host:443`, handshake + ALPN `h3`, таймаут 1с.
- Успех → боевое соединение; отказ → TCP-фолбэк.
- После N неудач подряд (default 3) — хост в `denylist` на время (TTL 10м).

---

## 7. Конфигурация (YAML)

```yaml
# /etc/go-fwd-proxy/config.yaml

listen:
  - address: ":8443"
    tls:
      cert: "/etc/proxy-certs/fullchain.pem"
      key: "/etc/proxy-certs/privkey.pem"
    alpn: ["h2", "http/1.1"]        # опционально "h3" на ребре

auth:
  users:
    - username: "admin"
      password: "nyxprod"           # plaintext ИЛИ bcrypt "$2a$14$..."

# ---- Лестница путей ----
paths:
  l1_masque:                        # UDP-релей / CONNECT-UDP
    enabled: true
  l2_h3_client:                     # прокси сам ходит по HTTP/3 (http://)
    enabled: true
    handshake_timeout: 1s
    consecutive_fails_to_blacklist: 3
    blacklist_ttl: 10m
    allowlist: []                   # домены: всегда L2
    denylist: []                    # домены: никогда L2
  l3_tcp:                           # чистый TCP / CONNECT-туннель
    enabled: true

# ---- Обнаружение h3 ----
discovery:
  alt_svc_cache_ttl: 24h
  https_record_cache_ttl: 1h
  dns:
    resolver: ""                    # пусто = системный; "https://1.1.1.1/dns-query"

# ---- Адаптивный селектор (пробинг сети) ----
selector:
  probe_interval: 5m                # как часто пере-пробовать сеть
  probe_timeout: 2s
  probe_targets:                    # куда стучимся UDP/QUIC
    - "cloudflare.com:443"
    - "google.com:443"
  udp_block_threshold_loss_pct: 20  # потери UDP > 20% → считать UDP деградировавшим
  udp_block_threshold_success: 2    # 2 успешных пробинга подряд → вернуться к L1
  decision_cache_ttl: 10m

probe_resistance:
  enabled: true
  landing_html: ""

logging:
  level: info
  access: true

metrics:
  enabled: true
  addr: "127.0.0.1:9100"
  path: "/metrics"
```

---

## 8. Безопасность

- **No DNS leak:** резолвы доменов только через конфигурируемый резолвер (DoH по умолчанию).
- **Аутентификация:** basic auth, постоянное время сравнения, rate-limit по IP.
- **Таймауты:** dial, QUIC-handshake (1с), idle, чтение/запись заголовков (защита от slowloris).
- **Probe resistance** (§4.4).
- **Не логировать** пароли, куки, тела запросов.
- **TLS:** только TLS 1.2+, HTTP/2 preferred.
- **MASQUE/UDP-релей не читает трафик** — для конфиденциальности это плюс (E2E не нарушается).

---

## 9. Логирование и метрики

### 9.1. Access-лог (JSON)

```json
{"ts":"...","client":"1.2.3.4","method":"CONNECT-UDP","host":"netflix.com",
 "status":200,"path":"l1","transport":"quic-relay","bytes":12345,"duration_ms":120}
{"ts":"...","client":"1.2.3.4","method":"GET","host":"example.com",
 "status":200,"path":"l2","transport":"quic","bytes":2048,"duration_ms":45}
{"ts":"...","client":"1.2.3.4","method":"CONNECT","host":"netflix.com:443",
 "status":200,"path":"l3","transport":"tcp(tunnel)","bytes":9999,"duration_ms":80}
```

### 9.2. Метрики Prometheus

- `fwdproxy_requests_total{method,path,transport,status}`
- `fwdproxy_bytes_total{direction,path,transport}`
- `fwdproxy_path_selected{path}` — сколько раз выбран L1/L2/L3
- `fwdproxy_probe_total{target,proto}` / `fwdproxy_probe_loss_pct{target}`
- `fwdproxy_udp_blocked` — 1 если провайдер душит UDP
- `fwdproxy_quic_fallback_total{host}` / `fwdproxy_quic_handshake_seconds{host}`
- `fwdproxy_alt_svc_hits_total` / `fwdproxy_https_rr_hits_total`

---

## 10. Тестирование

### 10.1. Функциональное

```bash
# HTTP через прокси
curl -x http://admin:nyxprod@127.0.0.1:8443 http://example.com/ -v

# HTTPS (CONNECT → L3)
curl -x http://admin:nyxprod@127.0.0.1:8443 https://youtube.com/ -v

# Без auth → 407
curl -x http://127.0.0.1:8443 http://example.com/ -v

# Probe: GET / → обычная страница
curl http://127.0.0.1:8443/ -v
```

### 10.2. Проверка путей

- Сайт с h3 (Google/YouTube/Cloudflare): `http://`-запросы → `path: l2, transport: quic`.
- Сайт без h3: `path: l3`.
- **Симуляция блокировки UDP** (`iptables -A OUTPUT -p udp --dport 443 -j DROP`): пробинг фиксирует деградацию → селектор переводит трафик на L2/L3, `udp_blocked=1`.
- **Восстановление UDP:** после 2 успешных пробингов селектор возвращает L1.
- CONNECT-UDP (MASQUE): тест клиентом sing-box/браузером до Netflix, проверка что QUIC до Netflix реально идёт.

### 10.3. Производительность

- `wrk`/`oha` через прокси на большой файл: сравнить L2 vs L3.
- Проверка отсутствия утечек (`ss`, `netstat`).

### 10.4. Системная интеграция

- systemd, автозапуск, journald.
- `proxy_manager.sh` обновлён для записи юзеров в конфиг (§11).

---

## 11. Интеграция с сервером

- **Бинарь:** `/usr/local/bin/go-fwd-proxy`
- **Конфиг:** `/etc/go-fwd-proxy/config.yaml`
- **Unit:** `/etc/systemd/system/go-fwd-proxy.service`

```ini
[Unit]
Description=Go Forward Proxy (adaptive QUIC/MASQUE + HTTP/3 outbound)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/go-fwd-proxy -c /etc/go-fwd-proxy/config.yaml
Restart=always
RestartSec=3
User=proxy
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

- **proxy_manager.sh:** функции `add_naive_user`/`remove_protocol` после миграции правят
  `/etc/go-fwd-proxy/config.yaml` (и перезапускают unit), а не Caddyfile. Либо отдельный `users.yaml`.

---

## 12. Этапы разработки (компонента)

| Этап | Содержание | Критерий готовности |
|------|-----------|---------------------|
| **1. L3-фолбэк** | Листенер+TLS, basic auth, CONNECT, HTTP-проксирование, probe_resistance, access-лог | curl-тесты §10.1 зелёные |
| **2. L2 (HTTP/3 outbound)** | quic-go `http3.Transport`, выбор транспорта, Alt-Svc/HTTPS-RR кэши, QUIC-хендшейк с фолбэком | у h3-сайтов transport=quic |
| **3. L1 (MASQUE/CONNECT-UDP)** | UDP-релей; либо интеграция с sing-box как провайдером L1 | QUIC до Netflix через прокси |
| **4. Адаптивный селектор** | пробинг сети, лестница L1→L2→L3, circuit breaker, метрики | §10.2 зелёные |
| **5. Прод** | systemd, proxy_manager.sh, мониторинг, доки | §10.3–10.4 |

---

## 13. Зависимости (Go)

| Библиотека | Назначение |
|-----------|-----------|
| `github.com/quic-go/quic-go` + `.../http3` | HTTP/3-клиент и QUIC |
| `github.com/quic-go/masque-go` (или аналог) | MASQUE / CONNECT-UDP сервер |
| `golang.org/x/net/http2` | HTTP/2 по TCP |
| `net/http` + `golang.org/x/net/http/httpproxy` | базовый прокси-сервер |
| `golang.org/x/crypto/bcrypt` | bcrypt |
| `github.com/miekg/dns` (или DoH-клиент) | HTTPS/SVCB (тип 65) |
| `github.com/prometheus/client_golang` | метрики |
| `gopkg.in/yaml.v3` | конфиг |

> **Альтернатива L1:** не писать MASQUE самим, а использовать уже работающий sing-box
> (входящий naive с h3 + CONNECT-UDP) — см. §16.

---

## 14. Риски и открытые вопросы

- **Стабильность quic-go/masque** — нужно нагрузочное тестирование.
- **Основной трафик — HTTPS (CONNECT).** Для него L1 (UDP-релей) даёт QUIC, а L2/L3 — нет.
  Значит реальная ценность L2 ограничена `http://`.
- **Провайдер может душить QUIC даже «поверх TCP-прокси»** — L2 не панацея, если у сайта нет h3.
- **Кэши** — в памяти, теряются при рестарте; опц. сброс на диск.
- Вопрос: нужен ли **SOCKS5** сейчас?
- **Клиентская сторона:** селектор в идеале должен жить на клиенте (браузер/sing-box), чтобы выбирать
  L1 vs L2 на своей стороне; на сервере — только реализация путей + серверная диагностика.

---

## 15. Адаптивный транспортный селектор (ATS)

### 15.1. Проблема

Провайдеры ведут себя по-разному, и это меняется во времени/по протоколу:

| Поведение провайдера | Как влияет | Путь-победитель |
|----------------------|-----------|-----------------|
| UDP свободен | QUIC/QUIC-релей работают | **L1** |
| Блокировка UDP:443 (QUIC) | QUIC-релей и h3-клиент до сайтов умирают | **L2** (через TCP, `http://` → h3) |
| Блокировка UDP целиком | L1 и L2-хендшейки мёртвы | **L2** для h3-сайтов по TCP, иначе **L3** |
| Троттлинг UDP (потери/джиттер) | QUIC деградирует (потери > порога) | переключиться на **L2/L3** |
| DPI по SNI/протоколу прокси | Конкретный сервис (sing-box/naive) режется | резервный путь (Caddy/Go-прокси) |
| Время суток (пик = троттлинг) | Периодическая деградация | периодический пере-пробинг |

### 15.2. Лестница путей

```
L1 ──► QUIC-туннель + UDP-релей до цели (MASQUE/CONNECT-UDP, hysteria2, sing-box xudp)
L2 ──► TCP-форвард-прокси + HTTP/3-клиент на последней миле (Go-прокси/Envoy)
L3 ──► чистый TCP (CONNECT-туннели, HTTP/1.1-2)
```

### 15.3. Пробинг сети

Периодически (default `probe_interval: 5m`) сервер измеряет доступность UDP/QUIC:

1. QUIC-хендшейк до известных h3-хостов (`cloudflare.com:443`, `google.com:443`) — они
   почти гарантированно поддерживают QUIC, поэтому их «отказ» = проблема сети, не сайта.
2. Прямой UDP-echo/QUIC-хендшейк до самого прокси (проверка «своей» стороны).
3. Замеры: успех хендшейка, RTT, потери (loss %), джиттер.
4. Дополнительно: тест «UDP пакет до цели проходит» через CONNECT-UDP эхо.

### 15.4. Правила принятия решения

```
если UDP_OK (успех >= udp_block_threshold_success, loss < udp_block_threshold_loss_pct):
    → L1 (QUIC до цели через релей)
иначе если есть TCP-соединение до сервера:
    → L2 для http://-сайтов с h3; L3 для HTTPS/CONNECT и сайтов без h3
иначе:
    → L3 (последний шанс)
```

Решение кэшируется (`decision_cache_ttl`) и **пересматривается** каждые `probe_interval`.

### 15.5. Circuit breaker (динамика)

- **Downgrade:** при деградации текущего пути (потери UDP > порога, хендшейки падают,
  таймауты) → плавно перейти на путь ниже без обрыва пользовательской сессии.
  Например, L1→L2: переоткрыть поток по TCP, перенести уже установленные соединения.
- **Upgrade:** после `udp_block_threshold_success` успешных пробингов подряд → вернуть L1.
- Каждый переход логируется и попадает в метрику `fwdproxy_path_selected`.

### 15.6. Где живёт ATS

- **На сервере:** реализация путей (L1/L2/L3) + диагностика сети + рекомендация пути.
- **На клиенте (важно):** финальный выбор «как подключиться» (L1 через hysteria2/sing-box
  vs L2 через HTTP-прокси) должен делать **клиент** — он знает свою сеть лучше.
  Клиент пробует L1, при неудаче падает на L2-прокси. Сервер лишь обязан честно отвечать
  на каждый режим и отдавать статус (`/status` endpoint с текущим состоянием UDP).

### 15.7. Конфиг ATS (в §7)

---

## 16. Целевая архитектура (с учётом существующих сервисов)

### 16.1. Текущее состояние сервера (инвентаризация)

| Сервис | Порт | Роль сегодня | Потенциальная роль |
|--------|------|--------------|--------------------|
| **Caddy** v2.11.4 | :80, :443, :8080, :4433 | Web-edge, панель, `forward_proxy` (naive, :8443 в прошлом) | **L3** (запасной forward proxy) + web-edge |
| **sing-box** | :8443 (TCP+UDP) | naive inbound (h2/h3), юзеры | **L1** (CONNECT-UDP/MASQUE + h3 naive) |
| **hysteria2** | :30000 (UDP) | QUIC-туннель (свой протокол) | **L1** (QUIC-путь для совместимых клиентов) |
| **xray (VLESS+XHTTP+REALITY)** | :4433 | туннель | **L1/L3** (обход DPI, reality) |
| **AmneziaWG** | :39743 (UDP) | WireGuard-подобный | — |
| **uvicorn** | :8000-8002, :5000 | бэкенды (sleep, panel) | без изменений |
| **Go-прокси (новый)** | :8443 (новый) | — | **L2** (h3-клиент) + частично L1 |

### 16.2. Итоговая схема

```
                                ┌─► L1: hysteria2 :30000 (QUIC-туннель)
                                │    sing-box :8443 (naive h3 / CONNECT-UDP/MASQUE)
Клиент (sing-box/браузер) ──────┤
                                │─► L2: Go-прокси :8443 (TCP + HTTP/3-клиент на http://)
                                │
                                └─► L3: Caddy forward_proxy (запасной TCP-путь)
                                         xray :4433 (VLESS+REALITY, обход DPI)

                                  └── Go-прокси ──► HTTP/3 к сайтам с h3 (последняя миля)
                                  └── hysteria2/sing-box ──► UDP-релей QUIC до Netflix
```

Ключевые принципы:
1. **L1 = QUIC-пути** уже есть (hysteria2, sing-box). Их не надо писать с нуля — надо
   подключить к селектору и уметь падать на L2/L3.
2. **L2 = Go-прокси** — новый компонент, единственный, который даёт HTTP/3 на последней
   миле для `http://`-трафика.
3. **L3 = Caddy/xray** — оставить как страховку, не удалять до полного доверия к L2.
4. **Не «заменяем naive на Go», а добавляем Go-прокси как новое звено** и держим старые
   пути живыми для постепенного переключения клиентов.

### 16.3. Клиентская логика

- Клиент = sing-box (нативно понимает hysteria2/vless/naive) + HTTP-прокси для L2.
- Идеальный порядок подключения клиента:
  1. Пробует L1 (hysteria2 или naive/sing-box CONNECT-UDP).
  2. Если UDP мёртв → L2 (HTTP-прокси Go-прокси, где он умеет h3).
  3. Если и L2 недоступен → L3 (Caddy forward_proxy).
- sing-box `urltest`/`selector`/`fallback`-аутбаунды уже дают базовую версию этого (выбор
  сервера); для выбора **транспорта** (L1/L2/L3) нужен свой скрипт/конфиг или правка логики.

---

## 17. Пошаговый план внедрения

### Фаза 0. Аудит (1-2 дня)
1. Снять текущее состояние: `ss -tlnp`, `ss -ulnp`, `systemctl list-units`.
2. Проверить, что реально слушает :8443 (Caddy или sing-box) — не гадать, посмотреть.
3. Прогнать **пробинг UDP/QUIC с сервера** на cloudflare/google — зафиксировать,
   режет ли провайдер UDP с самого VPS.
4. Прогнать **пробинг с клиентской стороны** (пользователь) — узнать, как ведёт себя
   провайдер у реального пользователя (это главный вопрос!).
5. Зафиксировать вывод в `docs/STATUS.md`.

### Фаза 1. L3-фолбэк: Go-прокси «как есть» (3-5 дней)
1. Собрать MVP: листенер :8443, basic auth, CONNECT, HTTP-проксирование, probe_resistance.
2. Прогнать curl-тесты §10.1.
3. Поднять рядом (другой порт :8444) — не трогая работающий сервис.
4. Перевести тестового пользователя на :8444, проверить.

### Фаза 2. L2: HTTP/3 outbound (3-5 дней)
1. Добавить quic-go `http3.Transport`, Alt-Svc/HTTPS-RR кэши, пробный хендшейк.
2. Проверить §10.2: у h3-сайтов `transport=quic`.
3. Сравнить L2 vs L3 по скорости (§10.3).

### Фаза 3. L1: MASQUE/CONNECT-UDP (5-10 дней)
1. Оценить два пути:
   a) свой сервер CONNECT-UDP на Go (quic-go/masque);
   b) **использовать sing-box как провайдера L1** (быстрее, надёжнее, уже стоит).
2. Если (b) — настроить sing-box CONNECT-UDP/naive h3 на :8443, связать с клиентами.
3. Проверить «QUIC до Netflix» клиентом sing-box.

### Фаза 4. Адаптивный селектор (5-7 дней)
1. Реализовать пробинг (§15.3), правила выбора (§15.4), circuit breaker (§15.5).
2. `/status` endpoint на Go-прокси.
3. Клиент: скрипт/конфиг переключения L1↔L2↔L3.
4. Метрики и графики (Prometheus/Grafana).

### Фаза 5. Прод и автоматизация (3-5 дней)
1. systemd-юниты, proxy_manager.sh → новый конфиг, документация.
2. Постепенный перевод пользователей: test → Merlin/Katya → остальные.
3. Мониторинг деградаций, подкрутка порогов ATS.

**Итого:** ~2-4 недели работы при уверенном движении. Ключевой риск — клиентская сторона
(поведение провайдера у реальных пользователей), поэтому **Фаза 0 обязательна**.

---

## 18. Итог

- **Главное понимание:** «QUIC до Netflix» = **UDP-релей (MASQUE/CONNECT-UDP, L1)**, а не
  HTTP/3-клиент (L2). L2 полезен только для `http://`-трафика и как запасной путь.
- **L1 уже есть на сервере** (hysteria2, sing-box) — не надо изобретать.
- **Новое звено — Go-прокси (L2)** — единственный, кто умеет HTTP/3 на последней миле.
- **Ценность системы — в авто-выборе** между L1/L2/L3 под конкретного провайдера.
- МВП — **Фаза 1 (L3-фолбэк)**: готовая замена Caddy forward_proxy «как есть».
  Дальше L2 и L1 — эксперименты с измеримой ценностью через ATS.

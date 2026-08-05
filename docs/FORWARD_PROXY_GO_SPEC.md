# Спецификация: форвард-прокси на Go с HTTP/3 на последней миле

> Статус: черновик (v0.1)
> Цель: заменить Caddy `forward_proxy` (Naive, :8443) на собственный Go-прокси,
> который на исходящих соединениях (прокси → целевой сайт) использует **HTTP/3 (QUIC)**
> там, где сайт его поддерживает, с автоматическим фолбэком на TCP.

---

## 1. Обзор

```
Клиент ──(HTTPS + basic auth)──► Go-прокси :8443 ──(последняя миля)──► целевой сайт
                                    │
                                    ├── QUIC / HTTP/3  (если сайт поддерживает h3)
                                    └── TCP / HTTP/1.1-2 (иначе, фолбэк)
```

**Два участка соединения:**
- **Edge / inbound** — клиент → прокси. Протокол: HTTP CONNECT + HTTP-проксирование. Здесь QUIC не требуется (можем включить h3 на ребре опционально).
- **Last mile / outbound** — прокси → целевой сайт. Именно сюда добавляем HTTP/3.

**Ключевой нюанс:** HTTP/3 ускоряет только проксирование **HTTP-трафика** (`http://` URL). Для HTTPS-сайтов (`CONNECT host:443`) прокси передаёт сырые TLS-байты, где HTTP/3 неприменим в принципе — этот случай обрабатывается по TCP (см. §6.3).

---

## 2. Цели

- [ ] Работает как стандартный HTTP forward proxy: `curl -x http://user:pass@host:8443 http://...`
- [ ] Проксирует `http://`-запросы на целевую сторону **по HTTP/3**, если сайт поддерживает h3
- [ ] Автоматический фолбэк: QUIC не ответил → повторить по TCP (HTTP/1.1 / HTTP/2)
- [ ] Поддержка `CONNECT` для HTTPS-сайтов (сырой TCP-туннель)
- [ ] Basic-auth на входящей стороне (совместимость с текущим конфигом Caddy)
- [ ] Поведение как у Caddy forward_proxy: `hide_ip`, `hide_via`, `probe_resistance`
- [ ] Системные unit, метрики, access-лог с указанием использованного транспорта (quic/tcp)

## 3. Не входит в scope (non-goals)

- Туннели по QUIC для произвольного TCP (hysteria2, tuic и т.п.) — не делаем
- Reverse proxy / балансировка — не делаем
- Терминация TLS с MITM-перешифрованием HTTPS-туннелей — **не делаем** (это нарушает E2E)
- SOCKS5 — опционально, отдельным этапом (§13)

---

## 4. Входящая сторона (клиент → прокси)

### 4.1. Листенер

- Один HTTPS-listener `:8443` (свободен после вывода Caddy forward_proxy).
- TLS-серты: переиспользовать `/etc/proxy-certs/fullchain.pem` + `privkey.pem`.
- ALPN на ребре: `h2, http/1.1` (можно `h3` позже — на входящей стороне это легко).
- Поддерживаемые методы:
  - `CONNECT host:port` → открыть TCP-туннель до цели, вернуть `200 Connection established`.
  - `GET http://host/...`, `POST`, и т.д. → проксировать как обычный HTTP-запрос.
  - `GET /` (без URL) → отдать probe-страницу (§4.4).

### 4.2. Аутентификация

- HTTP Basic auth. Источник: файл конфига.
- Поддержка двух форматов пароля:
  - **plaintext** (`user: pass`) — совместимость с Naive/Caddy (`basic_auth admin nyxprod`);
  - **bcrypt hash** (`user: $2a$...`) — совместимость с bcrypt-хешами Caddy.
- Сравнение с постоянным временем (`crypto/subtle`), защита от перебора (rate-limit по IP — опционально).
- Валидация через ту же схему, что и у `proxy_manager.sh` (см. §11).

### 4.3. `hide_ip` / `hide_via`

- НЕ добавлять `X-Forwarded-For`, `X-Real-IP`, `Via` при проксировании.
- Стирать входящие `X-Forwarded-For` / `Via` из запроса перед отправкой на цель.

### 4.4. `probe_resistance`

- На любой запрос к корню без валидного auth **без** прокси-намерения (например, `GET /`, `GET /favicon.ico`, `HEAD /`) — отдавать нейтральный HTML (200) с «обычным сайтом», а не признаком прокси.
- `CONNECT` без auth → `407 Proxy Authentication Required`.
- Это повторяет поведение Caddy `forward_proxy { probe_resistance }`, чтобы не палить сервис сканерами.

---

## 5. Исходящая сторона (прокси → сайт)

### 5.1. Модуль выбора транспорта (outbound dialer)

Порядок выбора для `http://`-запросов:

1. **Кэш Alt-Svc** — если с этого хоста ранее получали заголовок `Alt-Svc: h3=":443"; ma=...` → пробуем QUIC.
2. **DNS HTTPS / SVCB запись** — `HTTPS` RR с `alpn="h3"` для домена (через DoH/DoT, чтобы не течь DNS) → пробуем QUIC.
3. **Пробный QUIC-хендшейк** (режим `auto`) — короткий таймаут (≤1с) на UDP:443 с ALPN `h3`. Успех → h3, иначе фолбэк на TCP.
4. **Принудительно** — если в конфиге домен в `allowlist` → всегда QUIC; в `denylist` → никогда.

Статус-машина одного запроса:

```
QUIC_TRY → (успех) HTTP/3
         → (таймаут/отказ/сброс) TCP_FALLBACK → HTTP/1.1 или HTTP/2 (ALPN)
```

### 5.2. Проксирование `http://`-запросов

- Собрать целевой URL из request-line (или `Host` + absolute-form).
- Выбрать транспорт (§5.1).
- Для QUIC: использовать `http3.Transport` (quic-go) как `http.RoundTripper`.
- Для TCP: `http.Transport` (HTTP/1.1 + HTTP/2 по ALPN).
- Перенести: метод, путь+query, заголовки, тело (`io.Copy`), trailers.
- Ответ цели → клиенту как есть (заголовки + тело + статус).

### 5.3. CONNECT-туннели (HTTPS-сайты)

- `CONNECT netflix.com:443` → **всегда TCP**. HTTP/3 неприменим: это сырой байтовый туннель без HTTP-семантики.
- Соединяемся `tcp://netflix.com:443`, затем `io.Copy` в обе стороны (клиент ↔ цель).
- Опционально: поддержка `UDP-over-TCP` (как SOCKS5) — отдельно, не требуется.
- В access-логе транспортом для CONNECT указывать `tcp (tunnel)`.

---

## 6. Обнаружение поддержки h3 у сайта

### 6.1. HTTPS DNS record (SVCB)

- Запрос `HTTPS <domain>` (тип 65).
- Если в ответе `alpn="h3"` → сайт поддерживает h3.
- Резолвить через DoH (Cloudflare/Google) или системный резолвер.
- Кэшировать результат с TTL (по умолчанию 1 ч).
- При отсутствии записи — считаем h3 неподтверждённым (переходим к пробному хендшейку / TCP).

### 6.2. Alt-Svc

- Из HTTP-ответов по TCP-пути кэшировать `Alt-Svc: h3=":port"; ma=seconds`.
- Хранить `host → (h3, порт, до_времени)`.
- При повторных запросах к хосту — сразу пробовать QUIC.

### 6.3. Пробный QUIC-хендшейк

- Dial UDP `host:443`, handshake QUIC + ALPN `h3`, с таймаутом `handshake_timeout` (по умолчанию 1с).
- Успех → используем это соединение для запроса (не «просто тест», а боевое).
- Отказ/сброс/таймаут → TCP-фолбэк.
- Защита от повторов: после N неудач подряд подряд (default 3) — поместить хост в `denylist` на время.

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
    # - username: "Merlin"
    #   password: "$2a$14$or1W8yh..."

outbound:
  default: auto                     # auto | tcp | quic
  quic:
    enabled: true
    handshake_timeout: 1s           # пробный QUIC-хендшейк
    fallback_to_tcp: true
    consecutive_fails_to_blacklist: 3
    blacklist_ttl: 10m
    allowlist: []                   # домены: всегда QUIC
    denylist: []                    # домены: никогда QUIC
  alt_svc_cache_ttl: 24h
  https_record_cache_ttl: 1h
  dns:
    resolver: ""                    # пусто = системный; или "https://1.1.1.1/dns-query"

probe_resistance:
  enabled: true
  landing_html: ""                  # путь к файлу с «обычной» страницей

logging:
  level: info                       # debug|info|warn|error
  access: true

metrics:
  enabled: true
  addr: "127.0.0.1:9100"
  path: "/metrics"
```

---

## 8. Безопасность

- **No DNS leak:** все резолвы доменов — только через конфигурируемый резолвер (по умолчанию системный; рекомендуем DoH).
- **Аутентификация:** basic auth, постоянное время сравнения, rate-limit по IP (опц.).
- **Таймауты:** dial, QUIC-handshake (1с), idle, чтение/запись заголовков (защита от slowloris).
- **Probe resistance** (§4.4): не светить сервис сканерам.
- **Не логировать** пароли, куки, тела запросов (только хост+метод+статус+транспорт+байты).
- **TLS** на ребре: только TLS 1.2+, HTTP/2 prefered.

---

## 9. Логирование и метрики

### 9.1. Access-лог (построчно, JSON)

```json
{"ts":"...","client":"1.2.3.4","method":"CONNECT","host":"netflix.com:443",
 "status":200,"transport":"tcp(tunnel)","bytes":12345,"duration_ms":120}
{"ts":"...","client":"1.2.3.4","method":"GET","host":"example.com",
 "status":200,"transport":"quic","bytes":2048,"duration_ms":45}
```

### 9.2. Метрики Prometheus (`/metrics`)

- `fwdproxy_requests_total{method,transport,status}`
- `fwdproxy_bytes_total{direction=in|out,transport}`
- `fwdproxy_quic_fallback_total{host}` — сколько раз QUIC→TCP
- `fwdproxy_quic_handshake_seconds{host}` — гистограмма
- `fwdproxy_alt_svc_hits_total` / `fwdproxy_https_rr_hits_total`
- `fwdproxy_up` — здоровье процесса

---

## 10. Тестирование

### 10.1. Функциональное (локально)

```bash
# HTTP через прокси (TCP-фолбэк ожидается для локального)
curl -x http://admin:nyxprod@127.0.0.1:8443 http://example.com/ -v

# HTTPS через прокси (CONNECT → туннель)
curl -x http://admin:nyxprod@127.0.0.1:8443 https://youtube.com/ -v

# Без auth → 407
curl -x http://127.0.0.1:8443 http://example.com/ -v

# Probe: GET / → обычная страница, а не признак прокси
curl http://127.0.0.1:8443/ -v
```

### 10.2. Проверка транспорта

- Сайт с h3 (Google, YouTube, Cloudflare): в access-логе `"transport":"quic"` для `http://`-запросов.
- Сайт без h3: `"transport":"tcp"`.
- Эмуляция отказа QUIC (фаервол UDP): фолбэк на TCP, запись в `quic_fallback_total`.
- Тест `allowlist`/`denylist`.

### 10.3. Производительность

- Прогнать `wrk`/`oha` через прокси на большой файл — сравнить TCP vs QUIC путь.
- Проверить отсутствие утечек соединений (`netstat`, `ss`), корректность close.

### 10.4. Системная интеграция

- `systemd` unit: автозапуск, рестарт, логи в journald.
- Порт :8443 освобождён (Caddy forward_proxy остановлен / переведён).
- `proxy_manager.sh` обновлён для записи юзеров в новый конфиг (§11).

---

## 11. Интеграция с сервером

- **Бинарь:** `/usr/local/bin/go-fwd-proxy`
- **Конфиг:** `/etc/go-fwd-proxy/config.yaml`
- **Unit:** `/etc/systemd/system/go-fwd-proxy.service`

```ini
[Unit]
Description=Go Forward Proxy (HTTP/3 outbound)
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

- **proxy_manager.sh:** функции `add_naive_user`/`remove_protocol` для naive — после миграции должны править `/etc/go-fwd-proxy/config.yaml` (и перезапускать unit), а не Caddyfile. Либо вести отдельный файл юзеров `users.yaml`, который читает прокси.

---

## 12. Этапы разработки

| Этап | Содержание | Критерий готовности |
|------|-----------|---------------------|
| **1. TCP-фолбэк** | Листенер+TLS, basic auth, CONNECT, HTTP-проксирование, probe_resistance, access-лог | `curl`-тесты из §10.1 зелёные |
| **2. HTTP/3 outbound** | quic-go `http3.Transport`, выбор транспорта (auto), Alt-Svc + HTTPS RR кэши, QUIC-хендшейк с фолбэком | §10.2: у h3-сайтов transport=quic |
| **3. Метрики и тюнинг** | Prometheus, rate-limit, blacklist, systemd, интеграция с proxy_manager.sh | §10.3–10.4 зелёные |
| **4. (опц.) SOCKS5** | SOCKS5-листенер, UDP-over-TCP | smoke-тест с браузером |

---

## 13. Зависимости (Go)

| Библиотека | Назначение |
|-----------|-----------|
| `github.com/quic-go/quic-go` + `.../http3` | HTTP/3-клиент (RoundTripper) |
| `golang.org/x/net/http2` | HTTP/2 по TCP |
| `golang.org/x/net/http/httpproxy` / `net/http` | базовый HTTP-сервер прокси |
| `golang.org/x/crypto/bcrypt` | проверка bcrypt-хешей |
| `github.com/miekg/dns` (или DoH-клиент) | HTTPS/SVCB-записи (тип 65) |
| `github.com/prometheus/client_golang` | метрики |
| `gopkg.in/yaml.v3` | конфиг |

---

## 14. Риски и открытые вопросы

- **Стабильность quic-go http3-клиента** — нужно нагрузочное тестирование на реальном сайте.
- **Усилия на последней миле:** QUIC-ускорение работает только для `http://`-запросов; HTTPS-трафик (основной) останется TCP. Нужно решить, оправдан ли этап 2 вообще, или достаточно TCP-прокси (этап 1).
- **Смешение версий:** no h3-кэш между протоколами — только в памяти процесса (потеряется при рестарте). Опц.: сохранять Alt-Svc-кэш на диск.
- **h3 на ребре** (клиент→прокси) — легко добавить (входящий QUIC), но не влияет на скорость последней мили.
- **Битва с NAT/сетями** для UDP: у некоторых клиентов QUIC режется — фолбэк обязателен.
- Вопрос: нужен ли **SOCKS5** сейчас или только HTTP-прокси?

---

## 15. Итог

- Go-прокси закрывает «белое пятно»: **веб-сервер, который сам ходит на сайты по HTTP/3**, чего нет ни у Caddy, ни у nginx, ни у Angie.
- Реалистичная ценность — только для `http://`-трафика и сайтов с h3 на плохих каналах. Основной HTTPS-трафик ускорить нельзя (CONNECT-туннели).
- Минимально жизнеспособный продукт — **этап 1 (TCP-фолбэк)**: это замена Caddy forward_proxy «как есть», уже полезная. Этап 2 (QUIC) — эксперимент с измеримой ценностью.

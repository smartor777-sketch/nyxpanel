# Миграция с Caddy на Angie (HTTP/3)

> Статус: черновик / план
> Цель: перевести edge-сервер с Caddy на Angie для нативной поддержки исходящего HTTP/3 (QUIC) к апстримам, сохранив все текущие маршруты: reverse_proxy, forward proxy, статику, авто-TLS.
> Актуально для: сервер `31.76.8.29`, стек: Caddy v2.11.4 на :80/:443.

---

## 1. Зачем это нужно (кратко)

Текущая архитектура:

```
Клиент ──(TCP/HTTP1.1, HTTP/2, HTTP/3)──► Caddy :80/:443
                                              ├── reverse_proxy → 127.0.0.1:8000 (uvicorn, sleep)
                                              ├── reverse_proxy → 127.0.0.1:5000 (Flask-панель)
                                              ├── forward_proxy (Naive-прокси) → целевые сайты
                                              └── file_server (статика /var/www/html, /opt/proxy-panel)
```

Проблема: **Caddy не умеет HTTP/3 в исходящих запросах** (Go `net/http` не имеет HTTP/3-клиента). Forward proxy и reverse_proxy ходят к апстримам/сайтам по TCP (HTTP/1.1/2).

**Angie** (форк Nginx от бывших core-разработчиков) поддерживает исходящий HTTP/3 через `proxy_http_version 3;` — QUIC к апстримам.

Важно: выигрыш от исходящего HTTP/3 появляется только если **целевой сайт поддерживает h3** **и** канал до него плохой (потери пакетов, длинная RTT). На быстром канале разница минимальна.

---

## 2. Что даёт HTTP/3 (QUIC) — тезисы

- **Устранение Head-of-Line Blocking** (в отличие от HTTP/2 по TCP): потеря пакета не блокирует остальные потоки.
- **0-RTT handshake** — повторные соединения устанавливаются мгновенно.
- **Устойчивость к смене сети** (migration) — соединение не рвётся при смене IP/Wi-Fi.
- **Нативно по UDP/443** — не режется файрволами, которые блокируют произвольные UDP-порты.

---

## 3. Список крупных сервисов с HTTP/3 + QUIC

Эти сервисы **отдают** HTTP/3, т.е. исходящий h3 с сервера будет работать именно с ними:

| Сервис | Поддержка h3 | Примечание |
|--------|--------------|------------|
| Google (YouTube, Поиск, Gmail, Drive, Maps) | ✅ | Google — автор QUIC, тестирует с 2018 г. |
| YouTube | ✅ | Видео-стриминг активно использует h3/QUIC |
| Meta (Facebook, Instagram, WhatsApp Web) | ✅ | |
| Netflix | ✅ | |
| Twitch | ✅ | |
| Cloudflare CDN (Wikipedia и ~35% топ-сайтов) | ✅ | Масса сайтов под h3 через CF |
| Apple | ✅ | |
| Microsoft | ✅ | |
| Amazon | ✅ | |
| X / Twitter | ✅ | |
| TikTok | ✅ | |
| Reddit | ✅ | |
| GitHub | ✅ | через Fastly/другое CDN |
| Telegram (Web) | ⚠️ | нестабильно/частично |

**Источник оценки:** статистика W3Techs — ~35%+ сайтов в топе уже отдают HTTP/3.

---

## 4. Подготовка (проверки перед миграцией)

### 4.1. Что стоит на сервере сейчас

```bash
# Проверка веб-сервера
caddy version
ss -tlnp | grep -E ':443|:80'

# Текущий конфиг Caddy
cat /etc/caddy/Caddyfile
```

### 4.2. Что нужно для Angie

Angie — это **отдельный пакет/сборка** (не nginx из репозиториев Debian).

- Репозиторий: `https://packages.angie.software/angie/` (Debian/Ubuntu пакеты).
- Для HTTP/3 нужна сборка с `--with-http_v3_module` **и** OpenSSL с QUIC API:
  - OpenSSL **3.5+** (нативная поддержка QUIC), либо
  - `quictls` / `BoringSSL` / AWS-LC.
- Проверьте, есть ли в вашем дистрибутиве OpenSSL 3.5+:
  ```bash
  openssl version
  ```

> Если OpenSSL < 3.5 — понадобится пересборка OpenSSL или установка quictls. Это самая трудоёмкая часть.

---

## 5. Сопоставление конфигураций: Caddy → Angie

### 5.1. Общая схема

| Caddy | Angie (nginx-синтаксис) |
|-------|--------------------------|
| `reverse_proxy 127.0.0.1:8000` | `proxy_pass http://127.0.0.1:8000;` |
| `handle /api/*` | `location /api/ { ... }` |
| `root * /path` | `root /path;` |
| `try_files {path} /index.html` | `try_files $uri /index.html;` |
| `header Cache-Control "..."` | `add_header Cache-Control "...";` |
| `tls email@example.com` (авто-выпуск) | `certbot` / вручную из `/var/lib/caddy/...` |
| `forward_proxy { ... }` | **нет прямого аналога** — см. 5.3 |
| `file_server` | `try_files $uri $uri/ =404;` |

### 5.2. Текущий Caddyfile → Angie

**Исходный Caddyfile** (`/etc/caddy/Caddyfile`):

```
sleep.kuban-forum.ru {
    handle /api/* {
        reverse_proxy 127.0.0.1:8000
    }
    handle {
        root * /srv/sleep-prod/frontend/dist
        try_files {path} /index.html
        file_server
    }
    header Cache-Control "no-cache, must-revalidate"
}

http://panel.kuban-forum.ru:8080 {
    root * /var/www/html
    file_server
    route /panel/* { reverse_proxy 127.0.0.1:5000 }
    route /user/*  { reverse_proxy 127.0.0.1:5000 }
    route /self/*  { reverse_proxy 127.0.0.1:5000 }
    route /samples/* { root * /opt/proxy-panel; file_server }
    route /static/*  { root * /opt/proxy-panel; file_server }
}

panel.kuban-forum.ru:443 {
    tls furi_wave@mail.ru
    route {
        handle /panel* { reverse_proxy 127.0.0.1:5000 }
        handle /user*  { reverse_proxy 127.0.0.1:5000 }
        handle /self*  { reverse_proxy 127.0.0.1:5000 }
        handle /samples/* { root * /opt/proxy-panel; file_server }
        handle /static/*  { root * /opt/proxy-panel; file_server }
        forward_proxy {
            basic_auth admin nyxprod
            hide_ip
            hide_via
            probe_resistance
        }
        root * /var/www/html
        file_server
    }
}
```

**Аналог на Angie** (`/etc/angie/sites-enabled/kuban-forum.conf`):

```nginx
# ---------- sleep.kuban-forum.ru ----------
server {
    listen 443 ssl;
    listen 443 quic reuseport;          # HTTP/3 inbound
    server_name sleep.kuban-forum.ru;

    http2 on;                           # Angie: включить HTTP/2
    ssl_certificate     /etc/letsencrypt/live/sleep.kuban-forum.ru/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/sleep.kuban-forum.ru/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    add_header Alt-Svc 'h3=":443"; ma=86400' always;   # рекламируем h3

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        add_header Cache-Control "no-cache, must-revalidate";
    }

    location / {
        root /srv/sleep-prod/frontend/dist;
        try_files $uri /index.html;
        add_header Cache-Control "no-cache, must-revalidate";
    }
}

# ---------- panel.kuban-forum.ru:8080 (HTTP) ----------
server {
    listen 8080;
    server_name panel.kuban-forum.ru;

    location /panel/  { proxy_pass http://127.0.0.1:5000; }
    location /user/   { proxy_pass http://127.0.0.1:5000; }
    location /self/   { proxy_pass http://127.0.0.1:5000; }

    location /samples/ { root /opt/proxy-panel; }
    location /static/  { root /opt/proxy-panel; }

    location / {
        root /var/www/html;
        try_files $uri $uri/ =404;
    }
}

# ---------- panel.kuban-forum.ru:443 (HTTPS) ----------
server {
    listen 443 ssl;
    listen 443 quic reuseport;          # HTTP/3 inbound
    server_name panel.kuban-forum.ru;

    http2 on;
    ssl_certificate     /etc/letsencrypt/live/panel.kuban-forum.ru/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/panel.kuban-forum.ru/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    add_header Alt-Svc 'h3=":443"; ma=86400' always;

    location /panel/ { proxy_pass http://127.0.0.1:5000; }
    location /user/  { proxy_pass http://127.0.0.1:5000; }
    location /self/  { proxy_pass http://127.0.0.1:5000; }

    location /samples/ { root /opt/proxy-panel; }
    location /static/  { root /opt/proxy-panel; }

    location / {
        root /var/www/html;
        try_files $uri $uri/ =404;
    }
}
```

### 5.3. Наив-прокси / forward proxy

Caddy `forward_proxy` — это **NaiveProxy-совместимый** forward proxy (HTTP CONNECT) с basicauth, `hide_ip`, `hide_via`, `probe_resistance`.

**В Angie нет встроенного аналога.** Варианты:

1. **Оставить Caddy только для forward proxy** на отдельном порту (например, :8443), а Angie на :80/:443 для всего остального. Миграция безопасная и обратимая.
2. Заменить NaiveProxy на отдельный процесс:
   - **naive** (Go-реализация, сам сервер NaiveProxy),
   - sing-box с inbound типа `naive` (уже есть на сервере на :8443!), либо
   - другие forward-прокси (3proxy, squid с basicauth — но без probe_resistance).

> Рекомендуемый план: **вариант 1** — сначала перевести :80/:443 на Angie, а forward proxy оставить на Caddy :8443 (или уже работающем sing-box :8443), затем при необходимости выпилить Caddy полностью.

### 5.4. TLS-сертификаты

Caddy выпускал серты сам в `/var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/...`.

Для Angie:
- Либо перейти на **certbot** (стандартный путь для nginx-синтаксиса):
  ```bash
  apt install certbot python3-certbot-nginx
  certbot certonly --nginx -d panel.kuban-forum.ru -d sleep.kuban-forum.ru
  ```
- Либо переиспользовать существующие серты Caddy (пути в `/var/lib/caddy/...`).

---

## 6. Пошаговый план миграции

### Фаза 0. Подготовка

1. Бэкап: `cp /etc/caddy/Caddyfile /root/backup_caddyfile.$(date +%F)`
2. Снимок сервера/снапшот VPS (если возможно).
3. Проверить OpenSSL:
   ```bash
   openssl version
   ```
4. Установить Angie:
   ```bash
   # Debian/Ubuntu — подключить репозиторий Angie
   curl -fsSL https://packages.angie.software/angie/angie-archive-keyring.asc \
     | gpg --dearmor -o /usr/share/keyrings/angie-archive-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/angie-archive-keyring.gpg] \
     https://packages.angie.software/angie/debian $(lsb_release -sc) main" \
     > /etc/apt/sources.list.d/angie.list
   apt update && apt install angie
   ```
   > Убедиться, что собран с `--with-http_v3_module` (проверка: `angie -V`).

### Фаза 1. Параллельный запуск (без остановки Caddy)

1. Angie слушает **свободные** порты (например, `:8443` для теста) или временные имена.
2. Прогнать проверку:
   ```bash
   angie -t
   ```
3. Проверить каждый маршрут через curl:
   ```bash
   curl -sI http://127.0.0.1:8443/panel/
   curl -sI http://127.0.0.1:8443/api/
   ```

### Фаза 2. Перевод на :80/:443

1. Остановить Caddy: `systemctl stop caddy` (или оставить на :8443).
2. Запустить Angie на :80/:443.
3. Проверка снаружи:
   ```bash
   curl -sI https://panel.kuban-forum.ru/
   # HTTP/3 (с сервера, где есть curl с nghttp3):
   curl -s --http3-only -o /dev/null -w '%{http_version} %{http_code}\n' https://panel.kuban-forum.ru
   ```
4. Проверить `Alt-Svc` в ответе.

### Фаза 3. Исходящий HTTP/3 (QUIC) к апстримам

Чтобы Angie ходил к сайтам/апстримам по HTTP/3:

```nginx
location / {
    proxy_http_version 3;            # HTTP/3 to upstream
    proxy_pass https://<upstream>;
    proxy_ssl_protocols TLSv1.3;     # для h3 обязателен TLS 1.3
}
```

Ограничения:
- `proxy_pass` обязан быть `https://...` (QUIC требует TLS).
- Кэш для h3 несовместим с h1/h2 — менять `proxy_cache_key` при смешивании.
- Мультиплексирование h3 в апстримах Angie: соединение на запрос, keepalive-аналог — на стадии развития.

### Фаза 4. Замена forward proxy

1. Оставить Caddy :8443 (Naive) ИЛИ настроить sing-box naive (уже есть на :8443).
2. Обновить конфиги клиентов: `https://<domain>:8443/` → новый адрес.
3. После перевода всех клиентов — `systemctl disable --now caddy`.

### Фаза 5. Проверка и откат

- **Rollback:** вернуть Caddy на :80/:443, Angie остановить.
- Проверка всех протоколов панели (`proxy_manager.sh list_users`, скачивание конфигов).
- Мониторинг логов: `journalctl -u angie -f`.

---

## 7. Риски и подводные камни

| Риск | Комментарий |
|------|-------------|
| OpenSSL без QUIC API | HTTP/3 не включится. Нужен OpenSSL 3.5+/quictls/BoringSSL |
| Nginx-синтаксис вместо Caddyfile | Весь конфиг переписывается, это не 1:1 |
| Авто-TLS Caddy → certbot | Ручное управление сертами + renewal |
| `forward_proxy` не имеет аналога | Нужен отдельный процесс (naive/sing-box/3proxy) |
| `proxy_manager.sh` пишет в Caddyfile | Скрипт содержит `add_naive_user` → правит `/etc/caddy/Caddyfile`; после миграции надо обновить логику |
| Кэш h1/h2/h3 несовместим | При смешанных апстримах менять `proxy_cache_key` |
| UDP-файрвол | QUIC идёт по UDP/443 — убедиться, что UDP/443 не заблокирован |
| h3 в исходящих ограничен | Работает только с сайтами, поддерживающими h3 (см. раздел 3) |

---

## 8. Проверочные команды

```bash
# Версия и модули
angie -V

# Тест конфига
angie -t

# HTTP/3 входящий (curl с nghttp3)
curl -s --http3-only -o /dev/null -w '%{http_version} %{http_code}\n' https://panel.kuban-forum.ru

# Alt-Svc
curl -sI https://panel.kuban-forum.ru/ | grep -i alt-svc

# UDP-порт 443 открыт?
ss -ulnp | grep :443

# Логи
journalctl -u angie -n 50
```

---

## 9. Итог

- **Angie** — единственный из "nginx-семейства", у кого исходящий HTTP/3 работает из коробки (`proxy_http_version 3`).
- Миграция **не тривиальная** (другой синтаксис, TLS, forward proxy), но **обратимая**: Caddy можно оставить на :8443 до полной замены.
- Реальный прирост — только к сайтам с h3 (Google/YouTube, Cloudflare CDN и т.д.) на плохих каналах.

> Открытый вопрос перед стартом: нужен ли именно исходящий HTTP/3 сейчас, или достаточно HTTP/3 на входящей стороне (которое Caddy уже делает). Если цель — только "современные стандарты на ребре", проще оставить Caddy и докупить QUIC-клиент на отдельном процессе.

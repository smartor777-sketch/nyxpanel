# Статус проекта NYX Panel

## Dev-стенд (2.26.51.8, nyx.kuban-forum.ru)

### Выполнено

- **AWG**: reboot в новое ядро (6.12.95), модуль загружен, сервис active
- **olcRTC**: собран с форка `smartor777-sketch/olcrtc-users`, сервис active
- **DNS**: A-запись `nyx.kuban-forum.ru → 2.26.51.8` создана через masterhost
- **Все 8 сервисов** (Xray, Caddy, sing-box-naive, Mita, AWG, Hy2, olcRTC, panel) active на dev
- **Caddy**: пересобран с `xcaddy` + `github.com/caddyserver/forwardproxy` (forward_proxy + панель)
- **sing-box**: готовый бинарник с GitHub Releases, Naive inbound на `:8443`
- **Caddyfile**: `route { handle /panel* → :5000, forward_proxy {...}, reverse_proxy https://zarazaex.xyz }`
- **proxy_manager_dev.sh**: обновлён и залит на dev, домен `nyx.kuban-forum.ru`
- **Hy2**: переключён с self-signed на Let's Encrypt (Caddy certs), `systemd.path` для авто-синка сертификатов
- **Hy2 auth**: single password → `auth.type: userpass` (per-user)
- **Xray**: StatsService API включён (gRPC на 127.0.0.1:10085), `email` поле добавлено клиентам
- **VLESS**: исправлен path (`%2Fvless` → `%2F`) — совпадает с сервером
- **AWG**: пользователи добавлены для всех существующих аккаунтов (4 peers)
- **Collector**: реальный сбор трафика для Xray (gRPC statsquery -reset), Hy2 (trafficStats API на 127.0.0.1:30100), AWG (`awg show` + pubkey map)
- **Cron**: `*/5 * * * * python3 /opt/proxy-panel/collector.py >> /var/log/panel-collector.log 2>&1`
- **Panel**: PrefixMiddleware для `/panel/`, пагинация (10/25/50), Export dropdown (subscription + cfg/qr), Chart.js с Today/Week/Month/All + user selector
- **Subscription endpoint**: `/panel/api/v1/sub/{name}` — base64 для V2Ray-клиентов (по User-Agent), config links для остальных
- **Mieru**: подтверждён ручной ввод (NekoBox не поддерживает subscription для Mieru)
- **Roadmap**: пункт 11 добавлен в `AGENTS/panel.md` (log-agent для Caddy/Mieru)

### Адаптивная вёрстка + PWA (24 Jul 2026)

- **Responsive mobile layout**: таблица юзеров в `self_admin.html` заменена на карточки на мобильных (≤768px), горизонтальный скролл убран
- **Адаптивные CSS**: `self.html`, `self_admin.html`, `self_login.html`, `manual.html`, `index.html`
  - Кнопки периодов (All/Week/Month) — flex-wrap
  - Сетки protocol-grid / app-grid — одна колонка на мобилках
  - Header — колонка на мобилках
  - Dropdown Export — полная ширина карточки
- **PWA**: `manifest.json`, `service-worker.js`, иконки 192/512
- **Перенаправление `/`**: корневой URL редиректит на `/self/login` (Middleware + Caddy)

### Caddy → sing-box: переход NaiveProxy (25 Jul 2026)

- **Проблема**: Caddy v2.8+ + `klzgrad/forwardproxy` перестал работать с Naive-клиентами (connection reset). forwardproxy шлёт стандартный HTTP CONNECT, Naive-клиент ждёт модифицированный CONNECT (с padding). Caddy не отличает.
- **Решение**: sing-box `:8443` с NaiveProxy inbound — понимает Naive-вариант CONNECT
- **Caddy**: больше не слушает `:8443`. Только `:443`: панель + forward_proxy (для обычных HTTPS-прокси) + reverse_proxy fallback
- **Сборка Caddy**: теперь через `xcaddy` с `github.com/caddyserver/forwardproxy` (не apt!)
- **sing-box**: готовый бинарник с GitHub Releases (не компилируется)
- **Итог**: два параллельных входа — Caddy `:443` (обычный CONNECT + панель) и sing-box `:8443` (Naive)

### Миграция портов (24 Jul 2026)

- **xray**: перенесён с 443 → **4433** (VLESS+Reality)
- **UFW**: порт 4433 добавлен (`ufw allow 4433/tcp`)
- **VLESS конфиги**: все `.uri` файлы обновлены (порт 443 → 4433)
- **QR коды**: пересозданы для всех юзеров
- **proxy_manager.sh**: `VLESS_PORT="4433"`

### В работе

- (none)

### GitHub

| Проект | URL |
|--------|-----|
| NYX Panel | [`github.com/smartor777-sketch/nyxpanel`](https://github.com/smartor777-sketch/nyxpanel) |
| olcRTC (модифицированный) | [`github.com/smartor777-sketch/olcrtc-users`](https://github.com/smartor777-sketch/olcrtc-users) |
| olcbox (KMP клиент) | [`github.com/smartor777-sketch/olcbox`](https://github.com/smartor777-sketch/olcbox) |

### Prod (31.76.8.29, panel.kuban-forum.ru)

- **Panel**: v1.06 (SQLite + API + collector + subscription), актуальная версия
- **Collector**: cron `*/5 * * * *`, сбор Xray (gRPC) + Hy2 (trafficStats) + AWG (awg show)
- **База**: SQLite с пользователями (Alexander, Katya, Merlin, Silky, test)
- **Caddy**: `/panel*` reverse_proxy на Flask 127.0.0.1:5000, basicauth
- **Старая панель**: сохранена как `/opt/proxy-panel/app.py.bak`
- **Домен**: `panel.kuban-forum.ru` (A-запись → 31.76.8.29, Cloudflare DNS, без proxy)
- **DNS**: `ns2.q11.ru` (masterhost), TTL 600s

### Изменения v1.05

- **Версия панели**: `PANEL_VERSION = "1.05"` (app.py), отображается как `v1.05` на всех страницах

- **Self-host Chart.js**: убран внешний CDN (`cdn.jsdelivr.net/npm/chart.js@4`), график грузится из
  локального `/static/chart.js` (файл `panel/proxy-panel/static/chart.js`, v4.5.1) — отдаётся Caddy
  через `handle /static/* { root * /opt/proxy-panel; file_server }`. Актуально для обоих макетов
  (`index.html`, `self_admin.html`, `self.html`).

- **Редирект после добавления сервиса**: 10 редиректов `redirect(url_for("index"))` заменены на
  `redirect(request.referrer or url_for("index"))` — после add/delete протокола или юзера возврат
  на ту же страницу (без «прыжка» между `/panel/` и `/self/`).

- **Caddy: доступ к API трафика без basicauth** (прод): добавлен блок
  `handle /panel/api/* { reverse_proxy 127.0.0.1:5000 }` перед `handle /panel* { basicauth ... }`,
  иначе session-авторизованный админ получал 401 на `/panel/api/v1/traffic` и график не рисовался.
  `/panel/` остаётся под basicauth.

- **Панель под systemd**: на проде запуск через `panel.service` (`/etc/systemd/system/panel.service`,
  `Restart=always`), перезапуск — `systemctl restart panel`.

## install.sh_status

Файл `server/install.sh` — не соответствует текущей архитектуре:

| Что в install.sh | Что надо |
|-----------------|----------|
| Caddy из apt (без forwardproxy) | Caddy из xcaddy с `github.com/caddyserver/forwardproxy` |
| Caddyfile: только панельные маршруты | Caddyfile: `route { handle /panel*, forward_proxy, reverse_proxy fallback }` |
| No sing-box LE cert sync | sing-box использует `/etc/letsencrypt/live/$DOMAIN/*` — те же certs, что Caddy |
| Caddy :8080 (лишний блок) | Не нужен — всё на :443 |
| Caddy :8443 не упомянут | Уже не нужен (Naive на sing-box) |

**Нужно обновить**: Caddy сборку через xcaddy, Caddyfile с forward_proxy, fallback, sync certs для sing-box.

### Hopper (тест на стенде, только dev — НЕ в панели)

- **Что это**: `ZonD80/hopper` — multi-hop L3-VPN поверх SSH (`hopperd`), управляется мобильным
  приложением (iOS/App Store, Android/Google Play). Не прокси-протокол: нет per-user QR/подписки,
  трафик считает сам демон (`~/.hopper/.../hopper.log`), поэтому в панель NYX **не интегрируется**
  (архитектурно не ложится в модель «юзер+протокол»). Поставлен на стенд как отдельная нода.

- **Установка**: штатный `install.sh --configure` → бинарь `hopperd-linux-amd64` (~4.2 МБ, из
  GitHub-релиза, версия 2.0.0), Python-venv, CLI `hopperctl`. Go для сборки не нужен (качается
  готовый бинарь). Предпосылки стенда: `x86_64`, `/dev/net/tun`, `ip`/`iptables`/`python3`, SSH:22.

- **Управление**: `hopperctl` (Python) — `status` / `start --chain-id UUID --role exit|relay --addr
  A.B.C.D --index N [--stop-only]`. Overlay/порт/TUN выводятся из chain UUID (`10.64.{octet}.0/24`,
  `listen_port 7400+octet`, iface `hopper_<chain>`). `hopperd` слушает только loopback, доступен
  через SSH-форвардинг; поднимается приложением при коннекте (systemd-сервиса нет by design).

- **Root vs не-root**: TUN требует root — `ip tuntap add` даёт `ioctl(TUNSETIFF): Operation not
  permitted` даже с `setcap cap_net_admin` на `ip` (file-cap не наследуется не-root процессом).
  Полностью не-root Hopper поднять нельзя.

- **Ограниченный доступ (реализовано на стенде)**: создан отдельный не-root юзер `hopper` со своим
  паролем (НЕ root). Приложение коннектится как `hopper` (не-root shell) и получает root только на
  один бинарь управления Hopper через sudo, не на shell/файлы. Root-деплой (`user root`) остаётся
  запасным вариантом.

- **ВАЖНО — первая версия sudo была небезопасна (security theater)**: изначально код Hopper лежал в
  `/home/hopper/hopper` под владельцем `hopper`, а sudo указывал на файл там же. Юзер `hopper` мог
  перезаписать сам sudo-таргет / python-код / бинарь `hopperd` (всё выполняется как root) →
  тривиальная эскалация в полный root (классическая дыра sudo: writable target). Проверено фактически.

- **Hardening (применён и проверен на стенде)**: весь исполняемый как root код вынесен в root-owned
  `/opt/hopper` (`chown -R root:root`, `chmod -R go-w`), домашняя папка `hopper` больше не содержит
  кода. Схема:
  - `/opt/hopper/hopperctl.bin` — root-owned launcher: `cd /opt/hopper`, `HOPPER_DIR/PYTHONPATH=/opt/hopper`,
    `PYTHONSAFEPATH=1` (блокирует import-hijack через `os.py` в cwd), `exec /usr/bin/python3 -m hopper.cli`.
  - `/usr/local/bin/hopperctl` (root-owned, в PATH) — если не root, делает `sudo -n /opt/hopper/hopperctl.bin`.
  - `/etc/sudoers.d/hopper`: `hopper ALL=(root) NOPASSWD: /opt/hopper/hopperctl.bin` (+ `env_keep HOME`,
    чтобы данные писались в `/home/hopper/.hopper`).
  - `setcap cap_net_admin+ep` на `/opt/hopper/dist/hopperd-linux-amd64` (per-file, системные `ip`/`iptables`
    НЕ трогаются).
  - Зависимости stdlib-only (`requirements.txt` пустой) → venv не нужен, используется системный `python3`.

- **Разделение код/данные**: код = `/opt/hopper` (root, ro для hopper). Данные (ключи, чейны,
  `hopper.json`, `registry.json`) = `/home/hopper/.hopper` (hopper-owned). `hopperd` запускается как root,
  но читает конфиг-данные — это сетевые параметры (addr/overlay/port/next-host), не команды.

- **Верификация hardening (стенд)**: `hopper` НЕ может писать `hopperctl.bin` / `cli.py` / `hopperd` /
  `/usr/local/bin/hopperctl` (all `ro`); НЕ может подменить папки (`/opt`, `/opt/hopper` — `ro-dir`);
  import-hijack через cwd `os.py` заблокирован (`PYTHONSAFEPATH`); при этом `hopperctl status` и
  `start` под `hopper` работают (`ready:true, nat:true`), `hopperd` бежит от root из `/opt/hopper`,
  ключи/конфиг остаются в `/home/hopper/.hopper`.

### Hopper — multi-user (как раздать нескольким людям)

- **Per-user конфигов/подписок/лимитов трафика НЕТ** (это не VLESS). «Юзеры» реализуются двумя путями:
  - **Multi-device на одну цепочку**: overlay `/24` → пул `10.64.{octet}.2–.254` → до ~250 клиентов
    одновременно; каждому уникальный адрес по lease (обновляется, пока подключён; протухает ~1 час).
    На практике — раздать один профиль сервера (JSON/QR) нескольким людям.
  - **Multi-chain**: несколько независимых цепочек, у каждой свой UUID → свой overlay/порт/TUN
    (`hopper_<chain>`); один VPS может быть entry в одной и exit в другой. Лимит — число TUN-интерфейсов
    хоста. **ВНИМАНИЕ**: «изоляция групп» здесь номинальная (см. тест ниже) — на одном хосте не enforced.

### Hopper — тест сетевой изоляции (стенд, 2 цепочки)

Проверено кодом (`routes.go` / `session.go` / `nat_linux.go` / `tun_linux.go`) + снятым состоянием ядра
при двух поднятых цепочках. Измеренные факты:

```
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0        ← отключается host-wide
net.ipv4.conf.default.rp_filter = 0
TUN: <addr>/32 + route 10.64.{octet}.0/24 dev hopper_<chain>
iptables filter FORWARD: policy ACCEPT, на каждый TUN «-i/-o hopper_X -j ACCEPT»
iptables nat POSTROUTING: MASQUERADE только «-s <overlay> -o <ens3>» (интернет-выход)
```

- **(a) Клиенты одной цепочки НЕ изолированы**: пакет A→B на exit-ноде заворачивается `ViaTun` → в TUN →
  ядро (`/24 dev tun`, `ip_forward=1`, `FORWARD -o tun ACCEPT`) → `tunReader` находит сессию B в registry
  → доставляет B. Клиенты видят друг друга по overlay-IP.
- **(b) Соседние цепочки на одном хосте НЕ изолированы**: пакет `10.64.X.2 → 10.64.Y.3` идёт по
  default-route чейна A в `hopper_A` → ядро видит `10.64.Y.0/24 dev hopper_B` → правило
  `FORWARD -i hopper_A ACCEPT` пропускает → в `hopper_B` → демон B доставляет. Путь двунаправленный;
  cross-chain masquerade нет, поэтому B видит реальный src `10.64.X.2`.
- **Вывод**: multi-chain даёт только номинальное L3-разделение (разные подсети/TUN), но **не
  enforced-изоляцию** на общем хосте. Настоящая изоляция групп — только на **разных VPS**.

**Побочные находки (безопасность):**
1. `hopperd` при NAT-сетапе ставит `rp_filter=0` **host-wide** — ослабляет anti-spoofing всего сервера.
2. **Утечка iptables-правил**: `--stop-only` не удаляет FORWARD/MASQUERADE-правила; со временем таблица
   растёт stale-записями для несуществующих TUN/подсетей. (На стенде вычищено вручную.)

### Hopper — СТАТУС: экспериментальная фича, НЕ включаем в прод

- Организация нескольких клиентов на Hopper **работоспособна и в целом безопасна**, но «стены тонкие»:
  запаса прочности на многослойную защиту нет (единичный слой iptables `ACCEPT` + host-wide `rp_filter=0`,
  нет per-user лимитов/учёта, утечка правил, TUN требует root).
- Помечено как **experimental**: в панель NYX не интегрируется, **в продакшен пока не включаем**.
  Держим как исследовательскую ноду на стенде. Подробности настройки — `docs/HOPPER.md`.
- Стенд после тестов **очищен**: все `hopper_*` FORWARD-правила и `10.64.*` MASQUERADE удалены, TUN сняты,
  процессы `hopperd` остановлены, `registry.json` обнулён, тестовые чейны (вкл. `42edbf5c`) удалены.

### Логи и ротация (оба сервера)

Настроена единая политика хранения логов для всех сервисов. Файлы ротируются по размеру/времени,
старые архивы удаляются автоматически. **Время на серверах — UTC** (новые сутки в 00:00 UTC = 03:00 МСК).

| Что | Механизм | Период | Хранение | Подробнее |
|-----|----------|--------|----------|-----------|
| `journald` (все systemd-сервисы) | `SystemMaxUse=200M`, `RuntimeMaxUse=50M`, `MaxRetentionSec=7day` | — | до 200 MB + 7 дней | `/etc/systemd/journald.conf.d/limit-size.conf` |
| `panel-collector.log` | logrotate weekly | неделя | 4 недели | `/etc/logrotate.d/panel-collector` |
| Xray `access.log` | logrotate daily × copytruncate | день | 7 дней | `/etc/logrotate.d/xray` |
| Xray `error.log` | logrotate weekly × copytruncate | неделя | 8 недель | `/etc/logrotate.d/xray` |
| Остальное (dpkg, apt, wtmp, btmp) | logrotate (штатный) | monthly | 12 месяцев | `/etc/logrotate.d/` — as-is |

Конфигурация logrotate (созданы файлы `/etc/logrotate.d/panel-collector` и `/etc/logrotate.d/xray`):

```text
# /etc/logrotate.d/panel-collector
/var/log/panel-collector.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}

# /etc/logrotate.d/xray — access (daily × 7)
/var/log/xray/access.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}

# /etc/logrotate.d/xray — error (weekly × 8)
/var/log/xray/error.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

Примечания:
- `copytruncate` для Xray: демон держит файловый дескриптор лога; без `copytruncate` пришлось бы
  слать сигнал (SIGUSR1) на переоткрытие. `copytruncate` копирует файл и обнуляет оригинал — атомарно,
  без сигнала.
- `panel-collector.log` открывается заново при каждом запуске cron (раз в 5 мин), поэтому используется
  `create` — файл воссоздаётся сразу после ротации.
- `delaycompress`: предыдущий архив остаётся несжатым один цикл (удобно для `tail -f` старых логов).
- journald до 500 MB — запас с учётом 4-6 systemd-сервисов (Caddy, Xray, Hy2, AWG, panel, Mita);
  при достижении лимита journald удаляет самые старые записи.

### Dev: установка сервисов (binary vs сборка)

| Сервис | Источник бинарника | Компиляция? |
|--------|--------------------|-------------|
| **Caddy** | `xcaddy` сборка с `github.com/caddyserver/forwardproxy` | **Да** — стандартный binary c caddyserver.com не включает forwardproxy |
| **sing-box** | GitHub Releases (`SagerNet/sing-box`) | **Нет** — готовый бинарник |
| **xray** | GitHub Releases (`XTLS/Xray-core`) | **Нет** |
| **Hysteria2** | GitHub Releases (`apernet/hysteria`) | **Нет** |
| **Mieru (mita)** | GitHub Releases (`.deb`) | **Нет** |
| **olcRTC** | GitHub Releases (`smartor777-sketch/olcrtc-users`) | **Нет** |
| **AWG** | apt (`amneziawg`) | **Нет** (DKMS модуль) |

⚠️ `install.sh` (в `server/`) не описывает текущую архитектуру — требует обновления (см. install.sh_status).

## Архитектура Caddy + forward_proxy + sing-box + NaiveProxy

### Схема

```
Интернет
   │
   ├── HTTPS proxy client → Caddy :443 (forward_proxy) →target site
   │                        ↑ обычный CONNECT с Basic Auth
   │
   ├── Naive клиент → sing-box :8443 (Naive inbound) →target site
   │                  ↑ Naive-модифицированный CONNECT
   │
   └── browser → Caddy :443 → /panel/* /user/* /self/* → Flask :5000
                              ├─ fallback → zarazaex.xyz (остальное)
```

### Caddy на `:443` — точка входа (HTTPS)

Принимает **все** HTTPS-соединения на 443 порту. Маршрутизация через `route { ... }`:

```
Запрос → Caddy :443
         │
         ├─ /panel/*, /user/*, /self/*, /samples/*, /static/* → Flask панель :5000
         │
         ├─ CONNECT-запрос (forward_proxy) → HTTPS-туннель к целевому хосту
         │
         └─ всё остальное → reverse_proxy на zarazaex.xyz (прикрытие)
```

### forward_proxy — Caddy как обычный HTTPS-прокси

Это стандартный **HTTP CONNECT proxy**. Клиент (браузер curl) настраивается как HTTPS-прокси на `nyx.kuban-forum.ru:443`, передаёт логин/пароль (Basic Auth). Caddy открывает туннель.

**Caddy НЕ знает про NaiveProxy** — он просто шлёт CONNECT.

### NaiveProxy — надстройка поверх CONNECT

NaiveProxy — не отдельный протокол, а **клиент** (Chromium-движок), который делает обычный HTTPS-CONNECT, но добавляет случайный padding и кастомные заголовки, чтобы обходить DPI.

### Зачем sing-box на `:8443`?

**Проблема:** Caddy + `klzgrad/forwardproxy` **сломали** Naive-клиенты с Caddy v2.8+. forwardproxy отправляет стандартный HTTP CONNECT, а Naive-клиент ждёт Naive-модифицированный CONNECT (с padding). Caddy их не отличает — шлёт обычный CONNECT. Naive-клиент получает connection reset.

**Решение:** sing-box имеет встроенный **NaiveProxy inbound** — он понимает Naive-модифицированный CONNECT. Клиенты подключаются к `nyx.kuban-forum.ru:8443` напрямую с TLS. Sing-box принимает Naive-соединение, расшифровывает, маршрутизирует трафик.

### Зачем держать Caddy, если sing-box всё умеет?

Caddy — **легитимный HTTPS-сервер** с панелью и сайтом-заглушкой. Это прикрытие: сканер на `:443` видит сайт, а не просто открытый порт. Sing-box на `:8443` — скрытый порт только для Naive, не очевиден.

### Caddyfile (dev)

```caddy
nyx.kuban-forum.ru:443 {
    tls furi_wave@mail.ru

    route {
        handle /panel/* { reverse_proxy 127.0.0.1:5000 }
        handle /user/*  { reverse_proxy 127.0.0.1:5000 }
        handle /self/*  { reverse_proxy 127.0.0.1:5000 }
        handle /samples/* { reverse_proxy 127.0.0.1:5000 }
        handle /static/* { reverse_proxy 127.0.0.1:5000 }

        forward_proxy {
            basic_auth test    577a43faa9ce2c8199752c79
            basic_auth 123     e9410cd68c75010ce087f108
            # ...
            hide_ip
            hide_via
            probe_resistance
        }

        reverse_proxy https://zarazaex.xyz {
            header_up Host {upstream_hostport}
        }
    }
}
```

## Текущая конфигурация портов (Prod + Dev)

| Сервис | Порт | Протокол | Назначение |
|--------|------|----------|------------|
| xray (VLESS+Reality) | **4433** | TCP | Прокси-трафик клиентов |
| Caddy | **443** | TCP+TLS | Панель (`/panel*`) + forward_proxy + fallback |
| Caddy (http→https) | **80** | TCP | Редирект на HTTPS |
| sing-box (NaiveProxy) | **8443** | TCP+TLS | NaiveProxy inbound |
| Hysteria2 | **30000** | UDP | Hy2 трафик |
| Mieru | **444-448** | TCP+UDP | Mieru трафик |
| olcRTC | **39743** | UDP | WebRTC трафик |
| AWG | — | UDP | WireGuard tunnel |
| panel (Flask) | **5000** | TCP (localhost) | Внутренний API Flask |
| xray API | **10085** | TCP (localhost) | gRPC stats |

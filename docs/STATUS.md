# Статус проекта NYX Panel

## Dev-стенд (2.26.51.8, nyx.kuban-forum.ru)

### Выполнено

- **AWG**: reboot в новое ядро (6.12.95), модуль загружен, сервис active
- **olcRTC**: собран с форка `smartor777-sketch/olcrtc-users`, сервис active
- **DNS**: A-запись `nyx.kuban-forum.ru → 2.26.51.8` создана через masterhost
- **Все 7 сервисов** (Xray, Caddy, Mita, AWG, Hy2, olcRTC, panel) active на dev
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

### В работе

- (none)

### GitHub

| Проект | URL |
|--------|-----|
| NYX Panel | [`github.com/smartor777-sketch/nyxpanel`](https://github.com/smartor777-sketch/nyxpanel) |
| olcRTC (модифицированный) | [`github.com/smartor777-sketch/olcrtc-users`](https://github.com/smartor777-sketch/olcrtc-users) |
| olcbox (KMP клиент) | [`github.com/smartor777-sketch/olcbox`](https://github.com/smartor777-sketch/olcbox) |

### Prod (31.76.8.29, 76t05pyu.ikill.baby)

- **Panel**: v1.05 (SQLite + API + collector + subscription), обновлена
- **Collector**: cron `*/5 * * * *`, сбор Xray (gRPC) + Hy2 (trafficStats) + AWG (awg show)
- **База**: SQLite с мигрированными пользователями (Alexander, Katya, Merlin, Silky, test)
- **Caddy**: `/panel*` reverse_proxy на Flask 127.0.0.1:5000, basicauth
- **Старая панель**: сохранена как `/opt/proxy-panel/app.py.bak`

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
    (`hopper_<chain>`); один VPS может быть entry в одной и exit в другой. Изоляция групп. Лимит —
    число TUN-интерфейсов хоста.

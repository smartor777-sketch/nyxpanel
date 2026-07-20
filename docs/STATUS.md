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

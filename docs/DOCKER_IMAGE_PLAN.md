# Docker-образ NYX Panel — оценка реализуемости

Статус: план / исследование, без реализации.
Дата: 2026-11-06.

Связанные документы: `docs/DOCKER_FIREWALL.md` (UFW, DNAT и `DOCKER-USER`),
`docs/TPROXY-GUIDE.md` (nftables/TPROXY на хосте).

## 1. Короткий ответ

Реалистично, но не как «один образ со всеми сервисами». Рабочая схема — **core-образ с
панелью и userspace-прокси + опциональные профили compose** для того, что требует
ядра и сетевого стека хоста.

Оценка: **2–3 недели** неполного дня. Примерно 70% риска сосредоточено в трёх местах:
AmneziaWG, tproxy (nftables/TPROXY) и olcRTC + Jitsi.

## 2. Что контейнеризуется без проблем

| Сервис | Порты | Почему просто |
|---|---|---|
| Flask-панель (gunicorn) | 127.0.0.1:5000 | Обычный Python-процесс, состояние — SQLite |
| Caddy + forwardproxy | 443/tcp | Собирается `xcaddy` в builder-стадии, конфиг в volume |
| Xray (VLESS+REALITY) | 4433/tcp | Userspace-демон, ключи генерируются на первом старте |
| Hysteria 2 | 30000/udp | UDP-порт, привилегии не нужны |
| Mieru (mita) | 444–448/tcp | Один бинарник |
| sing-box (NaiveProxy) | 8443/tcp | Один бинарник |
| Trojan (trojan-go) | 9443/tcp | Один бинарник |

Это ~80% функциональности и почти весь трафик. Всё перечисленное уже сейчас живёт
на одном хосте и общается через `127.0.0.1`, то есть границы для контейнера
фактически уже проведены.

## 3. Блокеры

### 3.1 AmneziaWG

Сейчас ставится как kernel-модуль (DKMS) плюс `net.ipv4.ip_forward=1` и NAT
(`iptables -t nat -A POSTROUTING ...`, см. `server/install.sh`). В контейнере нужны
`/dev/net/tun` и `NET_ADMIN`, но модуль всё равно должен быть собран под ядро хоста.
Варианты:

- **A. Хост ставит модуль, контейнер только управляет интерфейсом.** Работает, но
  ломает идею «просто запусти образ»: появляется обязательный шаг на хосте и
  привязка к версии ядра при обновлениях.
- **B. Userspace-реализация (`amneziawg-go`).** Тогда TUN создаётся внутри
  контейнера и DKMS не нужен. Это и есть настоящий «просто образ», но требует
  отдельной проверки пропускной способности и стабильности.

Для AWG также важно, что `awg show awg0 dump` опрашивает коллектор трафика —
интерфейс обязан быть в том же network namespace, что и коллектор.

### 3.2 tproxy-server / MTProxy

Это nftables TPROXY + policy routing (`ip rule`, `ip route`), то есть операции над
сетевым стеком хоста (`server/tproxy/firewall.nft`, `tproxy-firewall.service`).
В контейнере работает только как privileged-контейнер в host network — контейнер,
который владеет сетью хоста. Изоляции нет, зато правила не конфликтуют с Docker.
Альтернатива — оставить tproxy на хосте и не тащить его в образ вообще.

### 3.3 Коллектор трафика ходит на localhost

`panel/proxy-panel/collector.py` опрашивает:

- `xray api statsquery --server=127.0.0.1:10085`
- `curl http://127.0.0.1:30100/traffic` (Hysteria 2)
- `awg show awg0 dump`
- `trojan-go -api list -api-addr 127.0.0.1:10000`

Значит все эти процессы обязаны находиться в одном network namespace с коллектором.
Варианты: один контейнер на всё core-хозяйство либо pod-паттерн
(`network_mode: "service:core"`). Разносить сервисы по bridge-сетям нельзя —
учёт трафика сломается.

### 3.4 `proxy_manager.sh` — это обёртка над systemd

`bin/proxy_manager.sh` содержит 12 вызовов `systemctl restart` (xray, hysteria2,
sing-box-naive, trojan-go и т.д.). В контейнере systemd нет и не нужен. Требуется абстракция управления процессами: `systemctl` → `s6-svc` /
`supervisorctl` / сигнал супервизору. Правка механическая, но объёмная и затрагивает
все сценарии `add_user` / `del_user` / `set_reality_mode`.

### 3.5 olcRTC + Jitsi

Сам бинарник olcRTC контейнеризуется легко, но за ним стоит Jitsi: prosody, jicofo,
jvb, coturn, SCTP. Это отдельный тяжёлый compose на несколько stateful-сервисов, а не
«ещё один бинарь в образе». Логичнее вынести в отдельный репозиторий/стек и не
смешивать с панелью.

## 4. Мелкие, но обязательные правки

1. **`PANEL_SECRET`.** Сейчас `app.secret_key = os.environ.get("PANEL_SECRET", os.urandom(16).hex())`.
   В контейнере рестарты частые, а без фиксированного секрета сессии слетают при
   каждом перезапуске. Секрет должен генерироваться на первом старте и лежать в volume.
2. **Пути и env.** Сейчас зашиты `/opt/nyxpanel`, `/var/lib/nyxpanel`,
   `/opt/proxy-panel`, `/root/proxy_manager.sh`. Нужны `NYX_ETC`, `NYX_STATE`,
   `NYX_DB`, `NYX_MANAGER`.
3. **sudo-модель.** Панель запускается непривилегированно и ходит в менеджер через
   sudoers-allowlist, а менеджер лежит с правами 750. В контейнере это не нужно:
   там уже root. Это упрощение кода, но другая модель безопасности — её надо явно
   зафиксировать в документации.
4. **Сертификаты.** Caddy делает ACME; данные Caddy (`/data`) обязаны быть в volume,
   иначе на каждый рестарт будет новый выпуск сертификата и риск упереться в лимиты
   Let's Encrypt.
5. **SQLite.** Один writer, файл в volume. Нужны backup/restore и понятная миграция
   схемы при обновлении образа.
6. **Права на файлы состояния.** Коллектор и менеджер пишут в `/var/lib/nyxpanel`;
   внутри контейнера uid должен быть стабильным между версиями образа.
7. **Реальный IP клиента.** В host network решается само собой; в bridge — нужен
   `X-Forwarded-For` и правка логов/лимитов.
8. **Healthcheck.** Проверка `GET /self/login` на 127.0.0.1 плюс проверка, что xray
   реально слушает 4433.
9. **UFW и Docker.** При `network_mode: host` Docker не вставляет свои iptables-правила,
   и UFW/nftables продолжают работать предсказуемо. При публикации портов через
   bridge Docker обходит UFW — классические грабли, которых надо избегать.
10. **Лицензии.** В образе окажутся GPL-компоненты (sing-box, trojan-go и др.). Для
    приватного использования не проблема, но публичный образ потребует доступности
    исходников.

## 5. Целевая архитектура

Один **core**-контейнер (панель + caddy + xray + hy2 + mita + sing-box + trojan),
запущенный в `network_mode: host` под s6-overlay. Причина «всё в одном» — не лень, а
localhost-API коллектора и общий набор портов. Разделение на несколько контейнеров
возможно позже через pod-паттерн, но ценой усложнения старта и healthcheck'ов.

```yaml
services:
  core:
    image: nyxpanel/nyxpanel:1.13
    network_mode: host          # localhost-API, реальные IP клиентов, UFW продолжает работать
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    env_file: [.env]
    volumes:
      - nyx-etc:/etc/nyxpanel
      - nyx-state:/var/lib/nyxpanel
      - caddy-data:/data
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:5000/self/login"]
      interval: 30s
      timeout: 5s
      retries: 3

  awg:                          # docker compose --profile awg up -d
    profiles: ["awg"]
    image: nyxpanel/awg:1.13
    network_mode: host
    cap_add: [NET_ADMIN, SYS_MODULE]
    devices: ["/dev/net/tun:/dev/net/tun"]
    volumes: [ nyx-state:/var/lib/nyxpanel ]

  tproxy:                       # docker compose --profile tproxy up -d
    profiles: ["tproxy"]
    image: nyxpanel/tproxy:1.13
    network_mode: host
    cap_add: [NET_ADMIN]
```

Почему `network_mode: host` — осознанный выбор: он даёт localhost-API, реальные IP
клиентов и предсказуемый firewall. Минус — нет порт-изоляции между сервисами.

### First boot

`entrypoint.sh` при старте:

1. Если нет `PANEL_SECRET` — сгенерировать и сохранить в volume.
2. Если нет ключей REALITY / AWG / токенов — сгенерировать (идемпотентно).
3. Если нет админ-пароля — сгенерировать и показать один раз в логе.
4. Инициализировать/мигрировать SQLite.
5. Передать управление супервизору (s6-overlay).

«Настройка после установки» — это как раз то, что панель уже умеет: REALITY-профиль,
пользователи, протоколы. Не хватает только идемпотентного first-boot и корректного
состояния «домена ещё нет» (Caddy без TLS, панель только на localhost).

## 6. Изменения в коде

| Файл | Что делать |
|---|---|
| `bin/proxy_manager.sh` | Управление сервисами через переменные `SVC_RESTART`; убрать зависимость от `/opt/nyxpanel` и `/root/proxy_manager.sh` |
| `panel/proxy-panel/app.py` | Пути из env, обязательный `PANEL_SECRET`, `_sudo_cmd` → прямой вызов (в контейнере root) |
| `panel/proxy-panel/collector.py` | Адреса API из env, `awg_last.json` в volume |
| `server/install.sh` | Не трогать: остаётся основным путём установки |
| новое `Dockerfile` | Multi-stage: builder тянет xray / caddy+xcaddy / hy2 / mita / sing-box / trojan-go / olcrtc |
| новое `docker-compose.yml` | core + профили `awg`, `tproxy` |
| новое `docker/entrypoint.sh` | First-boot + запуск s6 |
| новое `docker/README.md` | Установка, обновление, бэкап, миграция с bare-metal |

Миграция «с bare-metal на compose»: импорт `/etc/nyxpanel`, `/var/lib/nyxpanel`,
конфигов xray/caddy, сертификатов и `.db` в volumes; остановка systemd-юнитов.
Обратная миграция — тоже должна быть описана.

## 7. Этапы и оценка

| Этап | Результат | Дни | Риск |
|---|---|---|---|
| 0. Подготовка | Пути через env, абстракция управления сервисами, healthcheck | 1–2 | низкий |
| 1. Core-образ | Dockerfile, compose, s6, first-boot, volumes; панель + xray + caddy + hy2 + mita + naive + trojan | 3–5 | средний |
| 2. AmneziaWG | `amneziawg-go` + TUN + NAT внутри контейнера (или документированный DKMS на хосте) | 2–3 | высокий |
| 3. tproxy | nftables + policy routing в privileged-контейнере либо отказ от контейнеризации | 2–3 | высокий |
| 4. olcRTC + Jitsi | Отдельный compose (prosody, jicofo, jvb, coturn) | 3–5 | высокий |
| 5. Обвязка | CI-сборка, документация, миграция, тесты на чистой VPS | 2–3 | средний |

Итого: **13–21 день** суммарно; этапы 2–4 можно не делать вовсе.

## 8. Риски и как их снимать

- **AWG ломается при обновлении ядра хоста** (вариант A). Решение: вариант B с
  userspace-реализацией или пиннинг ядра.
- **Docker обходит UFW при публикации портов.** Решение: host network, без `ports:`.
- **Расхождение конфигов между bare-metal и образом.** Решение: один генератор
  конфигов (`proxy_manager.sh`), образ только задаёт пути и способ рестарта.
- **Два поддерживаемых способа установки.** Решение: `install.sh` остаётся основным,
  Docker — помечен как preview, пока не проживёт пару недель на реальной VPS.
- **Учёт трафика тихо ломается.** Решение: приёмочный тест «добавить пользователя →
  погонять трафик → появились строки в `traffic_log`» в чеклисте спайка.
- **Сессии слетают после рестарта.** Решение: фиксированный `PANEL_SECRET` в volume.

## 9. Рекомендация

1. Делать **core-образ + профили**, а не «всё в одном».
2. Docker — **второй** путь установки; `install.sh` не трогать и не объявлять устаревшим.
3. olcRTC/Jitsi вынести отдельно — это не про панель.
4. Начинать со спайка без AWG и tproxy: он покажет реальные места, где торчит
   `systemctl`, и даст ответ по срокам за пару дней.

## 10. Спайк: критерии приёмки

Собрать образ и поднять на чистой Debian 12/13 VPS (Docker Engine 26+, compose v2,
x86_64, `/dev/net/tun`). Считать спайк успешным, если:

- [ ] `docker compose up -d` поднимает core-контейнер, healthcheck зелёный;
- [ ] `GET /self/login` → 200, вход админом работает;
- [ ] карточка REALITY показывает `reality_status` и позволяет применить пресет;
- [ ] `add_user ... vless` создаёт конфиг, ссылка и QR отдаются;
- [ ] VLESS+REALITY, Hysteria 2, Mieru, NaiveProxy реально подключаются с клиента;
- [ ] `docker compose restart` сохраняет пользователей, конфиги, сертификаты и сессии;
- [ ] коллектор пишет строки в `traffic_log` после тестового трафика;
- [ ] логи всех сервисов видны через `docker compose logs`;
- [ ] обновление образа на новую версию не требует ручных правок в volumes.

Вне спайка: AmneziaWG, tproxy, olcRTC/Jitsi, ARM64.

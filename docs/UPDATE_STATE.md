# Автообновления: текущее состояние

> **Это снимок, а не регламент.** Здесь записано, что *фактически* развёрнуто на хостах
> на момент съёма. Правила, окна, процедуры и обоснования — в [`UPDATE_PLAN.md`](UPDATE_PLAN.md).
>
> Снимок: **2026-11-10, 16:50 UTC** (Prod), 17:50 CET (Dev).
> Проверено по живому состоянию: `systemctl`, `sha256sum`, `dpkg`, `docker`.
>
> **Правило расхождений:** если этот файл спорит с сервером — верен сервер.
> Расхождение означает, что снимок устарел, и его нужно переснять (§9), а не «починить» сервер под документ.

---

## 1. Хосты

| | Prod | Dev |
|---|---|---|
| Hostname | `DE-LC-Production.play2go.cloud` | `Dev.play2go.cloud` |
| Доступ | `ssh prod`, 87.120.186.100 | `ssh dev`, 31.77.15.162 |
| ОС | Debian 13 trixie, x86-64 | Debian 13 trixie, x86-64 |
| Ядро | `6.12.116+deb13-amd64` | `6.12.116+deb13-amd64` |
| TZ | `Etc/UTC` | `Europe/Berlin` (CET, +0100) |
| Docker | **есть**: 29.9.3 / compose 5.7.0 | **нет** |
| Роль в схеме | security + Engine + образы | только security |
| `reboot-required` | нет | нет |

Docker-таймеры (`nyx-*`) существуют **только на Prod**. `ops/install-update-schedule.sh`
ставит их по факту наличия `docker` в `PATH`, поэтому на Dev они не появляются.

---

## 2. Расписание, которое реально в системе

### Prod (UTC)

| Слой | Юнит | `OnCalendar` | Следующий | Последний | Статус |
|---|---|---|---|---|---|
| Debian, скачивание индексов | `apt-daily.timer` | `*-*-* 01:30:00 UTC` | 2026-11-11 01:30 | 2026-11-10 02:33:51 | enabled, active |
| Debian, установка security | `apt-daily-upgrade.timer` | `*-*-* 02:00:00 UTC` | 2026-11-11 02:00 | 2026-11-10 03:06:31 | enabled, active |
| Docker Engine | `nyx-docker-engine-update.timer` | `Tue *-*-01..07 03:00:00 UTC` | **2026-12-01 03:00** | — | enabled, ни разу не срабатывал |
| Образы контейнеров | `nyx-containers-update.timer` | `Tue *-01,04,07,10-08..14 03:00:00 UTC` | **2027-01-12 03:00** | — | enabled, ни разу не срабатывал |
| Авторебут | `unattended-upgrades.service` | по событию, `04:00 UTC` | — | — | enabled, active |
| Инвентарь нативных приложений | `nyx-apps-inventory.timer` | `Tue *-*-01..07 03:30:00 UTC` | **2026-12-01 03:30** | — | enabled, never fired |

> «Последний» у apt-таймеров — от **старого** расписания (`RandomizedDelaySec=60m`, ~03:00).
> Первое точное срабатывание нового — 11.11 в 01:30 и 02:00 UTC.

### Dev (drop-in'ы в UTC, local = CET)

| Слой | `OnCalendar` | Следующий (local) | = UTC | Последний (local) |
|---|---|---|---|---|
| `apt-daily.timer` | `*-*-* 01:30:00 UTC` | 2026-11-11 02:30 CET | 01:30 | 2026-11-10 02:40:41 |
| `apt-daily-upgrade.timer` | `*-*-* 02:00:00 UTC` | 2026-11-11 03:00 CET | 02:00 | 2026-11-10 03:02:41 |

Авторебут на Dev — те же `04:00 UTC` (05:00 CET).

Инвентарь нативных приложений стоял и на Dev (таймер включён, `python3` в PATH): окно `03:30 UTC` =
`04:30 CET`, следующий запуск — 2026-12-01 04:30 CET. Dev отчитывается в свой же инвентарь; docker-таймеры
(`nyx-docker-engine`, `nyx-containers`) на Dev не ставятся, они не нужны (Docker там отсутствует).

> `Persistent=false` у docker-таймеров: если хост лежит в момент окна, запуск **не** догоняется,
> а ждёт следующего окна. Для apt-таймеров `Persistent=true` — пропущенный security-апдейт догоняется.

---

## 3. Установленные файлы и контрольные суммы

Все значения совпадают с `HEAD` репозитория (сверено `sha256sum` по LF-нормализованному содержимому).

### Prod

| Файл на хосте | sha256 (первые 16) |
|---|---|
| `/usr/local/sbin/nyx-docker-engine-update.sh` | `567684abda7c9380` |
| `/usr/local/sbin/nyx-containers-update.sh` | `bea4893d814689a8` |
| `/etc/systemd/system/nyx-docker-engine-update.service` | `99ce2b083058da6c` |
| `/etc/systemd/system/nyx-containers-update.service` | `f7419d74e45e56d1` |
| `/etc/systemd/system/nyx-docker-engine-update.timer` | `636054390b475a47` |
| `/etc/systemd/system/nyx-containers-update.timer` | `38011d236d736de0` |
| `/etc/systemd/system/apt-daily.timer.d/override.conf` | `2827143739112853` |
| `/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf` | `2797922ffea2fa85` |
| `/usr/local/sbin/nyx-apps-inventory.py` | `bc3aa381af49416` |
| `/etc/systemd/system/nyx-apps-inventory.service` | `7ed475b6aea4b698` |
| `/etc/systemd/system/nyx-apps-inventory.timer` | `56245d44383fdc19` |
| `/etc/nyx-updates/apps-inventory.tsv` | `501958547389f0a09` |

### Dev

| Файл на хосте | sha256 (первые 16) |
|---|---|
| `/etc/systemd/system/apt-daily.timer.d/override.conf` | `2827143739112853` |
| `/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf` | `2797922ffea2fa85` |

Docker-скриптов и юнитов на Dev нет.

### Что в юнитах

```ini
# nyx-docker-engine-update.service (и nyx-containers-update.service — аналогично)
Wants=network-online.target docker.service
After=network-online.target docker.service
ExecStart=/usr/local/sbin/nyx-<...>.sh
```

`Requires=docker.service` **нет** намеренно: рестарт `dockerd` при обновлении `docker-ce`
убивал бы юнит вместе с дочерним `dpkg` (инцидент 2026-11-10, см. `UPDATE_PLAN.md` §3).
`Environment=` в юнитах не задан — работают дефолты retention, зашитые в скрипты.

### `nyx-apps-inventory.service`

Без зависимости от docker — для нативного слоя это и правильно.

```
[Unit]
Description=Inventory of native applications (versions, sha256, upstream releases)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/nyx-apps-inventory.py
Nice=10
```


---

## 4. Debian security

`/etc/apt/apt.conf.d/51unattended-upgrades-local` — **идентичен на Prod и Dev**:

| Параметр | Фактическое значение |
|---|---|
| `Origins-Pattern` | только `Debian` / `trixie-security`, `label=Debian-Security` |
| `Automatic-Reboot` | `true` |
| `Automatic-Reboot-Time` | `04:00` |
| `Automatic-Reboot-WithUsers` | `true` |
| `Mail` | `furi_wave@mail.ru` |
| `MailReport` | `on-change` |
| `Remove-Unused-Kernel-Packages` | `false` |
| `Remove-Unused-Dependencies` | `false` |

`trixie-updates` (не-security) в автообновления **не входит** — ставится вручную.

---

## 5. Docker Engine (Prod)

| | Значение |
|---|---|
| `docker-ce` | `5:29.9.3-1~debian.13~trixie`, состояние `ii` |
| `docker-compose-plugin` | `5.7.0-1~debian.13~trixie` |
| `containerd.io` | `2.4.2-3~debian.13~trixie` |
| `docker-buildx-plugin` | `0.38.1-1~debian.13~trixie` |
| `docker-ce-rootless-extras` | `5:29.9.3-1~debian.13~trixie` |
| `dpkg --audit` | пусто |
| Скрипт | `/usr/local/sbin/nyx-docker-engine-update.sh`, дефолт `RETAIN_BACKUPS=6` |
| Лог | `/var/log/nyx-updates/docker-engine.log` |
| Бэкапы | `/root/backups/docker-engine/<stamp>/` |

---

## 6. Образы контейнеров (Prod)

Пин в `/opt/telegram-bot-api/docker-compose.yml`: **`aiogram/telegram-bot-api:10.3`**.

| Образ | ID | Размер | Возраст | Роль |
|---|---|---|---|---|
| `aiogram/telegram-bot-api:10.3` | `41721122b362` | 65,5 МБ | 27 ч | **активный** |
| `aiogram/telegram-bot-api:rollback-20261110-044311` | `c48c15017c2d` | 65,5 МБ | 6 нед | откат (тот же слой) |
| `aiogram/telegram-bot-api:rollback-20261110-151901` | `c48c15017c2d` | 65,5 МБ | 6 нед | откат (тот же слой) |
| `docker-wdtt-wdtt:latest` | `e1076183f710` | 175 МБ | 2 мес | **не используется** |

- Тег `:latest` у Bot API **снят** — контейнер не может уехать на плавающую версию.
- Два rollback-тега указывают на один и тот же слой (`c48c15017c2d`), то есть занимают место одного образа.
- Контейнер: `telegram-bot-api-telegram-bot-api-1`, образ `10.3`, `Up`.
- Проверка: Bot API отвечает `404` на `/` (норма), `docker exec ... telegram-bot-api --version` → `Bot API 10.3`.
- Скрипт: `/usr/local/sbin/nyx-containers-update.sh`, дефолты `RETAIN_BACKUPS=4`, `RETAIN_TAGS=2`.

Стеки, которые скрипт находит по label `com.docker.compose.project.working_dir`: только
`/opt/telegram-bot-api`. `docker ps` показывает один контейнер.

---

## 7. Что фактически произошло (журнал снимка)

| Когда (UTC) | Действие | Результат |
|---|---|---|
| 2026-11-10 02:33 / 03:06 | последние авто-прогоны apt по старому расписанию | успешно |
| 2026-11-10 13:51 | развёрнуты drop-in'ы и 4 юнита, таймеры enabled | `systemctl list-timers` показывает 4 юнита |
| 2026-11-10 13:51 | Bot API запинен `latest` → `10.3` | конфиг обновлён, образ ещё старый |
| 2026-11-10 14:00 | retention добавлен в скрипты, проверен на подставных каталогах | 6 → 4 каталога, 2 старых удалены |
| 2026-11-10 14:04 | прунинг легаси `/root/backups` | 217 МБ → 1,1 МБ |
| 2026-11-10 14:05 | ручной прогон Engine | **сбой**: `Requires=` убил юнит на `dpkg`, `docker-ce` остался `iF` |
| 2026-11-10 14:07 | починка: `dpkg --configure -a`, `Wants=`, self-heal | все пакеты `ii`, повторный прогон чистый |
| 2026-11-10 15:19 | ручной прогон образов | контейнер пересоздан на `10.3`, письмо отправлено, `:latest` снят |
| 2026-11-10 17:08 / 18:09 | включён инвентарь нативных приложений (`nyx-apps-inventory.timer`, 03:30 UTC) | prod: WDTT 1.5.73, xray 26.3.27, sing-box 1.12.4, hysteria 2.10.0, caddy 2.11.4, mita 3.34.0, panel 1.15; обновления: xray, sing-box, hysteria, caddy, mita, wdtt. dev: те же, где есть | письма sent |

Следующее, что случится **без участия человека**:

1. 2026-11-11 01:30 / 02:00 UTC — первые точные security-окна на Prod и Dev;
2. 2026-12-01 03:00 UTC — первое автоматическое окно Docker Engine;
3. 2026-12-01 03:30 UTC — первое автоматическое окно инвентаря нативных приложений;
4. 2027-01-12 03:00 UTC — первое автоматическое окно образов.

---

## 8. Бэкапы, логи, почта

| | Prod | Dev |
|---|---|---|
| `/root/backups` | 1,1 МБ | — |
| `.../docker-engine/` | `20261110-140542` (1 шт.) | — |
| `.../containers/` | `telegram-bot-api-20261110-044311`, `-151901` (2 шт.) | — |
| Логи обновлений | `/var/log/nyx-updates/{docker-engine,containers,apps}.log` | нет (только UU) |
| Лог UU | `/var/log/unattended-upgrades/unattended-upgrades.log` | тот же |
| Почта | `/usr/sbin/sendmail` → `uu-mailer.py` → `furi_wave@mail.ru` | так же |
| Последнее письмо | 2026-11-10 15:19 «container images updated» | — |

Retention (дефолты в коде, переменные окружения не переопределены):

| Что | Лимит |
|---|---|
| Каталоги бэкапов Engine | 6 |
| Каталоги бэкапов на стек | 4 |
| Теги `:rollback-*` на repo | 2 |
| `docker builder` cache | **не ограничен** |

---

## 9. Как переснять снимок

Один блок на хост — он же используется для сверки «документ vs реальность»:

```bash
ssh prod '
  hostnamectl | grep -E "Static hostname|Kernel"; timedatectl | grep "Time zone"
  systemctl list-timers apt-daily.timer apt-daily-upgrade.timer \
    nyx-docker-engine-update.timer nyx-containers-update.timer --no-pager --all
  systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer \
    nyx-docker-engine-update.timer nyx-containers-update.timer
  sha256sum /usr/local/sbin/nyx-docker-engine-update.sh \
            /usr/local/sbin/nyx-containers-update.sh \
            /etc/systemd/system/nyx-docker-engine-update.service \
            /etc/systemd/system/nyx-containers-update.service \
            /etc/systemd/system/nyx-docker-engine-update.timer \
            /etc/systemd/system/nyx-containers-update.timer \
            /etc/systemd/system/apt-daily.timer.d/override.conf \
            /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
  docker version --format "{{.Server.Version}}"; docker compose version
  docker ps --format "{{.Names}} {{.Image}} {{.Status}}"
  docker images --format "{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}"
  du -sh /root/backups; find /root/backups -maxdepth 2 -type d | sort
  dpkg --audit; test -f /var/run/reboot-required && cat /var/run/reboot-required
  dkms status; systemctl is-active awg-quick@awg0
'

ssh dev '
  timedatectl | grep "Time zone"
  systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager --all
  sha256sum /etc/systemd/system/apt-daily*.d/override.conf
  command -v docker || echo "no docker"
  dkms status; systemctl is-active awg-quick@awg0
'
```

После съёма: обновить дату в шапке, таблицы §2/§3/§5/§6/§8 и добавить строку в §7.
Если изменилось поведение (не только значения) — сначала правится `UPDATE_PLAN.md`, потом снимок.

---

## 10. Отклонения и долги

Известные расхождения между «как задумано» и «как сейчас» — сознательные или ожидающие решения:

| Что | Состояние | План |
|---|---|---|
| `docker-wdtt-wdtt:latest` | 175 МБ, контейнер не запущен — **удалён** 2026-11-10 | — (не запускался, источник в `/opt/proxy-turn-vk-android-server-fix/docker-wdtt/` оставлен) |
| build cache | ~175 МБ, 9 записей | `docker builder prune` по согласованию |
| Два rollback-тега на один ID | дублируют друг друга, лишнего места не занимают | уйдут сами по `RETAIN_TAGS=2` |
| `/opt/telegram-bot-api/docker-compose.yml` | режим `644`, `TELEGRAM_API_HASH` в открытом виде | `chmod 600` + вынос в env-файл |
| `trixie-updates` (не-security) | не ставятся автоматически, ждут ручного окна | 1-й вторник, вместе с проверкой Engine |
| Docker-таймеры ещё не срабатывали | `LAST = —`, включены 10.11.2026 | первое окно 01.12.2026 / 12.01.2027 |
| `docker builder` cache | лимита нет, растёт от сборок | при необходимости добавить prune в engine-скрипт |
| `nyx-qeli-tunnel.service` | чужой проект из общего каталога юнитов | не трогать |
| Слой 4 (нативные приложения) | автообновление не включено, есть инвентарь | WDTT/xray/sing-box/hysteria/caddy/mita/panel — снимок собирает, обновления ручные |

---

## 11. Связанные документы

| Документ | Про что |
|---|---|
| [`UPDATE_PLAN.md`](UPDATE_PLAN.md) | регламент: слои, окна, процедуры, откат, обоснования |
| [`AMNEZIAWG-DKMS.md`](AMNEZIAWG-DKMS.md) | модуль `amneziawg` после обновления ядра |
| [`DOCKER_FIREWALL.md`](DOCKER_FIREWALL.md) | `DOCKER-USER` guard, который проверяет engine-скрипт |
| `ops/ENVIRONMENT.md` | различия окружений (dev-стенд, порты, секреты) |

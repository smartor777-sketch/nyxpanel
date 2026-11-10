# План обновлений — prod

> Дата актуализации: 2026-11-10
> Хост: `DE-LC-Production` (`ssh prod`, 87.120.186.100), Debian 13 trixie, KVM, TZ = UTC
> Состояние на момент записи: ядро 6.12.116, Docker 29.9.2, Compose 5.6.1, Bot API 10.3
> Расписание: security Debian — 02:00 UTC; Docker Engine — 1-й вторник 03:00 UTC; образы — 2-й вторник квартала 03:00 UTC

Документ описывает, что обновляется само, что — руками, в каком порядке и как проверить/откатить.
Отдельно фиксируются два ручных трека, которые раньше нигде не были учтены: **Docker Engine** и **образ
`aiogram/telegram-bot-api`**.

---

## 1. Принцип: четыре независимых слоя

| Слой | Что входит | Кто обновляет | Периодичность |
|---|---|---|---|
| ОС и ядро | пакеты Debian, `linux-image`, `libc`, `openssl` | `unattended-upgrades` + авторебут | ежедневно, автоматически |
| Docker Engine | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` | systemd-таймер, §3 | 1-й вторник месяца, 03:00 UTC |
| Образы контейнеров (Docker images) | `aiogram/telegram-bot-api` (cobalt удалён 10.11.2026) | systemd-таймер, §4 | 2-й вторник янв/апр/июл/окт, 03:00 UTC |
| Код приложений | `nyxpanel`, `yt-bot`, боты, `wdtt-server` и т.п. | git + `systemctl restart` | по необходимости |

Ключевое: **обновление хоста не обновляет содержимое контейнеров**, а `docker compose pull` не обновляет
Docker Engine. Это разные треки с разными рисками.

---

## 2. Автоматическая часть (ОС и ядро) — уже настроено

Конфиг: `/etc/apt/apt.conf.d/51unattended-upgrades-local`, drop-in'ы
`/etc/systemd/system/apt-daily.timer.d/override.conf` и `apt-daily-upgrade.timer.d/override.conf`,
юнит `unattended-upgrades.service`, таймеры `apt-daily.timer` / `apt-daily-upgrade.timer`.

| Параметр | Значение |
|---|---|
| Источники | только `Debian` / `trixie-security` (`label=Debian-Security`) |
| Запуск | скачивание 01:30, установка **02:00 UTC** (`RandomizedDelaySec=0`) |
| Авторебут | `Automatic-Reboot "true"`, время `04:00` UTC, `WithUsers "true"` |
| Отчёты | `Unattended-Upgrade::Mail` на `furi_wave@mail.ru`, `MailReport "on-change"` |
| Старые ядра | `Remove-Unused-Kernel-Packages "false"`; сейчас в системе 6.12.115 (fallback) и 6.12.116 (running) |
| Логи | `/var/log/unattended-upgrades/unattended-upgrades.log` |

Регламент не требует действий: если обновилось ядро/`libc`/`systemd`, сервер сам перезагрузится в 04:00,
контейнеры и сервисы поднимутся по `restart: unless-stopped` / `systemd`.

На **dev** (`Dev.play2go.cloud`, TZ Europe/Berlin) стоят те же drop-in'ы: 01:30 и 02:00 UTC — это
02:30 и 03:00 по местному времени зимой. Docker на dev не установлен, docker-таймеры там не нужны.

**Проверка (раз в месяц, 1 минута):**

```bash
systemctl is-enabled unattended-upgrades && systemctl is-active unattended-upgrades
grep -E 'Automatic-Reboot|Origins-Pattern' /etc/apt/apt.conf.d/51unattended-upgrades-local
tail -n 30 /var/log/unattended-upgrades/unattended-upgrades.log
uname -r; dpkg -l 'linux-image-*' | grep '^ii'     # running == latest, fallback на месте
test -f /var/run/reboot-required && echo 'PENDING REBOOT' || echo 'no reboot needed'
last reboot -n 3
```

> `trixie-updates` (не-security) автоматически **не** ставится. Это осознанно: такие пакеты ставятся
> вручную, например в окно 1-го вторника вместе с проверкой после Docker Engine.

---

## 3. Docker Engine — автоматически, 1-й вторник 03:00 UTC

Сейчас: `docker-ce` **29.9.2**, `docker-compose-plugin` **5.6.1**. В очереди: **29.9.3** и **5.7.0**.

Обновляется таймером `nyx-docker-engine-update.timer` → `nyx-docker-engine-update.service` →
`/usr/local/sbin/nyx-docker-engine-update.sh`. Скрипт:

- делает `apt-get update` и проверяет только docker-пакеты (`docker-ce`, `docker-ce-cli`,
  `docker-ce-rootless-extras`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`);
- сохраняет версии, образы и список контейнеров в `/root/backups/docker-engine/<stamp>/`;
- обновляет пакеты, ждёт готовности `dockerd` (до 60 с);
- проверяет, что все ранее запущенные контейнеры снова `Running`, а цепочка `DOCKER-USER` не пуста;
- пишет лог в `/var/log/nyx-updates/docker-engine.log` и письмо на `furi_wave@mail.ru`
  при изменениях или ошибке.

**Почему отдельный таймер, а не `unattended-upgrades`:** пакеты идут из `download.docker.com`, этого
origin нет в security-политике UU. Свой таймер даёт выбранное окно, бэкап, проверку и уведомление,
не расширяя автоматику UU на сторонние репозитории.

**Dry-run и ручной запуск:**

```bash
/usr/local/sbin/nyx-docker-engine-update.sh --dry-run   # только показать, что обновится
systemctl start nyx-docker-engine-update.service        # выполнить окно сейчас
```

При обновлении `docker-ce` перезапустится `dockerd`: контейнеры перезапустятся автоматически
(`unless-stopped`), простой — единицы секунд. Если демон не поднялся сам — `systemctl restart docker`.

**Проверка после:**

```bash
docker version --format '{{.Server.Version}}'; docker compose version
systemctl is-active docker
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
iptables -t nat -S DOCKER                 # DNAT только на 127.0.0.1
iptables -t filter -S DOCKER-USER         # предохранитель на месте
curl -s -o /dev/null -w 'bot-api: %{http_code}\n' http://127.0.0.1:8082/   # 404 = сервер жив
```

`docker-fw-guard.service` помечен `PartOf=docker.service`, поэтому правила `DOCKER-USER`
переставляются после каждого рестарта демона — отдельно делать ничего не нужно, но проверить стоит.

**Откат** (если новая версия Engine ломает compose):

```bash
apt-get install -y --allow-downgrades \
  docker-ce=5:29.9.2-1~debian.13~trixie \
  docker-ce-cli=5:29.9.2-1~debian.13~trixie \
  docker-compose-plugin=5.6.1-1~debian.13~trixie
systemctl restart docker
```

Точные версии «до» всегда лежат в `/var/log/apt/history.log` и в нашем журнале §8.

---

## 4. Образ `aiogram/telegram-bot-api` — автоматически, 2-й вторник квартала

Сейчас: тег **`10.3`** (запинен 10.11.2026), образ от **2026-09-26**, внутри Bot API **10.3**.
`10.3` на Docker Hub пересобран 2026-11-09 (тот же Bot API, свежие Alpine-патчи) — его подтянет
ближайшее окно.

Обновляется таймером `nyx-containers-update.timer` (2-й вторник янв/апр/июл/окт, 03:00 UTC) →
`nyx-containers-update.service` → `/usr/local/sbin/nyx-containers-update.sh`. Скрипт:

- находит все **запущенные** compose-стеки по label `com.docker.compose.project.working_dir`;
- пропускает стек, где хоть один образ на `:latest` (защита от мажорных скачков);
- тегирует текущие образы `<repo>:rollback-<stamp>`, сохраняет compose и `rollback-map.txt`
  в `/root/backups/containers/<stack>-<stamp>/`;
- делает `docker compose pull` + `up -d --remove-orphans`;
- проверяет, что все сервисы стека `Running` и ничего не в `restarting`; при провале
  **автоматически откатывает** стек на `:rollback-<stamp>` и пишет письмо;
- лог: `/var/log/nyx-updates/containers.log`.

**Политика — пиновать версию Bot API, а не `latest`.** В `/opt/telegram-bot-api/docker-compose.yml`:

```yaml
services:
  telegram-bot-api:
    image: aiogram/telegram-bot-api:10.3    # было :latest до 10.11.2026
```

> `latest` + `restart: unless-stopped` = образ не обновляется сам: контейнер перезапускается из
> старого слоя, а тег в registry остаётся нетронутым.

Версии в апстриме: `10.3` (09.11.2026), `10.2` (24.08.2026), `10.1` (14.07.2026). Тег — мажор.минор
Bot API, без `-linuxamd64` (multi-arch index сам выберет amd64).

**Ручная процедура (вне окна / отладка):**

```bash
cd /opt/telegram-bot-api
STAMP=$(date +%F)

# 1. зафиксировать текущий образ, чтобы было куда откатиться
OLD=$(docker inspect --format '{{.Image}}' telegram-bot-api-telegram-bot-api-1)   # sha256:...
docker tag "$OLD" aiogram/telegram-bot-api:rollback-$STAMP

# 2. бэкап конфига
cp -a docker-compose.yml /root/backups/telegram-bot-api-compose-$STAMP.yml

# 3. обновить
docker compose pull
docker compose up -d

# 4. проверить
docker ps --filter name=telegram-bot-api
docker exec telegram-bot-api-telegram-bot-api-1 telegram-bot-api --version
docker logs --tail 20 telegram-bot-api-telegram-bot-api-1
```

**Проверка функционала:** отправить в `yt-bot` тестовое видео и убедиться, что файл доходит
(бот ходит в этот сервер через `TELEGRAM_API_BASE=http://127.0.0.1:8082`, режим `TELEGRAM_LOCAL=1`).
`GET /` возвращает `404` — это нормально, у Bot API нет корневого маршрута.

**Скрипт-помощник для ручного обновления одного стека:** `ops/update-containers.sh <compose_dir> [--apply]`
(тег `rollback-<дата>`, бэкап в `/root/backups/containers/`, `rollback-map.txt`, dry-run по умолчанию).
Автоматический таймер использует свой скрипт `/usr/local/sbin/nyx-containers-update.sh`, логика та же.

**Ручной откат (если автооткат не сработал):**

```bash
cd /opt/telegram-bot-api
# вернуть в compose тег rollback-<STAMP> и поднять
docker compose up -d
```

**Нюансы:**

- Данные (`./data` → `/var/lib/telegram-bot-api`) переживают обновление — это volume, не слой образа.
- При переходе на новую мажорную версию Bot API сначала читать release notes Telegram: меняются
  поддерживаемые методы/лимиты; `yt-bot` может требовать обновления aiogram/клиента.
- `TELEGRAM_API_ID` и `TELEGRAM_API_HASH` лежат в compose открытым текстом (права `644`). При случае
  вынести в `.env` с `600`; менять хеш — только с перевыпуском у BotFather.

---

## 5. Остальные контейнеры

На 10.11.2026 в Docker один контейнер — `telegram-bot-api`. Cobalt удалён (бэкап конфига:
`/root/backups/cobalt-20261110-043743.tar.gz`).

Правила для любого нового контейнера:

1. Пиновать версию в `image:` — не `latest` (исключение: сервис, у которого нет версионных тегов).
2. `restart: unless-stopped`.
3. Публиковать порты только как `127.0.0.1:PORT:PORT` — см. `docs/DOCKER_FIREWALL.md`.
4. Внести контейнер в таблицу §1 и в журнал §8.
5. Обновление — по процедуре §4 (pull → up -d → проверка → откат при необходимости).

Автоматическое обновление стеков делает `nyx-containers-update.timer` (§4): только пинованные теги,
с бэкапом, проверкой здоровья и автооткатом. Watchtower/diun не используем — они тянут `latest`
без проверок и без отката.

---

## 6. Календарь

| Когда | Что | Время |
|---|---|---|
| ежедневно | security-обновления Debian + ребут при необходимости | 01:30 / **02:00** / 04:00 UTC |
| ежемесячно, 1-й вторник | Docker Engine (таймер) + `trixie-updates` вручную | **03:00 UTC** |
| ежеквартально, 2-й вторник (янв/апр/июл/окт) | образы запущенных стеков (таймер) | **03:00 UTC** |
| по событию | новый Bot API (10.x → 11.x), CVE в базовом образе | окно обслуживания |
| раз в месяц | проверка логов UU и `/var/log/nyx-updates/`, `reboot-required`, `last reboot` | 5 минут |

Автоматические окна — 02:00 (Debian) и 03:00 UTC (Docker). Ручные работы планируются на тот же час,
кроме 04:00 — это время авторебута, его не занимаем.

### Почему Engine и образы — в разные окна

Это независимые переменные, и смешивать их в одном окне не стоит:

1. **Диагностика.** Если после одного окна сломался `yt-bot`, непонятно, виноват новый Engine,
   новый образ Bot API или их сочетание. С разнесением по времени причина однозначна.
2. **Разный откат.** Engine откатывается через `apt` downgrade + рестарт `dockerd` (влияет на все
   контейнеры и сеть), образ — через `docker tag` + `up -d` (влияет на один сервис). Держать эти
   операции раздельно проще, чем откатывать обе сразу.
3. **Разный blast radius.** Engine трогает сеть, iptables-guard, compose-совместимость и все
   контейнеры; образ — только Bot API. Инфраструктурное обновление должно «отстояться» до того,
   как поверх него меняется приложение.
4. **Проверка реестра.** Успешный `docker compose pull` после обновления Engine — это ещё и тест,
   что новый Engine корректно работает с registry и TLS. Если сначала обновить образ, а Engine
   сломает доступ к registry, картина запутается.

Практическое правило: **сначала Engine (1-й вторник), минимум сутки наблюдения, образы — не раньше
следующего окна** (у нас — 2-й вторник квартального месяца). Если оба обновления нужны срочно из-за
CVE, их можно совместить, но тогда: отдельные бэкапы, откат по шагам (сначала образ, потом Engine)
и запись обоих шагов в журнал §8.

---

## 7. Почему отдельный таймер, а не `unattended-upgrades`

`unattended-upgrades` намеренно ограничен security-архивом Debian. Docker CE приходит из
`download.docker.com` — это другой origin, и добавлять его в UU пришлось бы через `Origins-Pattern`,
получив ночной рестарт `dockerd` без бэкапа и проверок.

Отдельный таймер даёт то, чего UU не умеет: фиксированное окно (1-й вторник, 03:00 UTC), бэкап
версий, проверку контейнеров и `DOCKER-USER`, письмо с результатом и понятный ручной откат.

`trixie-updates` (не-security) сознательно остаётся ручным: там бывают изменения поведения
(`openssh`, `systemd`, `docker`), которые лучше ставить в окно с оператором. Docker-пакеты
обновляются своим таймером, поэтому в ручное окно попадают только редкие пакеты из `trixie-updates`.

---

## 8. Журнал

| Дата | Что | Результат |
|---|---|---|
| 2026-11-09 03:09 | UU: `linux-image` 6.12.115 → 6.12.116, headers, vim | авторебут 04:00, ядро активно |
| 2026-11-10 | аудит обновлений: UU работает, `reboot-required` нет | ручной ребут не требуется |
| 2026-11-10 | удалён контейнер/образ cobalt | освобождено ~438 МБ |
| 2026-11-10 | security-обновления перенесены на 02:00 UTC (prod и dev), drop-in'ы таймеров | включено |
| 2026-11-10 | таймеры: Engine — 1-й вторник 03:00 UTC, образы — 2-й вторник квартала 03:00 UTC | enabled, dry-run проверен |
| 2026-11-10 | Bot API запинен `latest` → `10.3`; Docker 29.9.2 → 29.9.3 в очереди | окна: 01.12.2026 и 12.01.2027 |

При каждом ручном обновлении добавлять строку: дата, что, версии «до → после», кто делал.

---

## 9. Чек-лист после автоматических окон

```
[ ] 02:05–02:20 UTC: tail /var/log/unattended-upgrades/unattended-upgrades.log — установка без ошибок
[ ] test -f /var/run/reboot-required; если есть — в 04:00 будет ребут
[ ] после 04:00 (если ребут был): uptime, uname -r, docker ps, systemctl --failed
[ ] 1-й вторник ~03:10: docker version, docker compose version, docker ps,
      iptables -S DOCKER-USER, письмо "Docker Engine updated"
[ ] 2-й вторник квартала ~03:10: docker ps, docker exec ... telegram-bot-api --version,
      тестовый файл через yt-bot, письмо "container images updated"
[ ] /var/log/nyx-updates/docker-engine.log и containers.log — без ERROR
[ ] при ERROR: откат по §3 / §4, запись в журнал §8
```

---

## 10. Файлы расписания и установка

Всё версионировано в `ops/` и ставится одним идемпотентным скриптом:

| Файл | Куда ставится |
|---|---|
| `ops/apt-daily.timer.override.conf` | `/etc/systemd/system/apt-daily.timer.d/override.conf` |
| `ops/apt-daily-upgrade.timer.override.conf` | `/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf` |
| `ops/nyx-docker-engine-update.sh` | `/usr/local/sbin/` |
| `ops/nyx-containers-update.sh` | `/usr/local/sbin/` |
| `ops/nyx-docker-engine-update.{service,timer}` | `/etc/systemd/system/` |
| `ops/nyx-containers-update.{service,timer}` | `/etc/systemd/system/` |
| `ops/install-update-schedule.sh` | не ставится, запускается из каталога `ops/` |
| `ops/update-containers.sh` | ручной помощник для одного стека |

Установка на хост:

```bash
# с локальной машины: скопировать ops/ на сервер и запустить
scp -r ops prod:/tmp/nyx-ops
ssh prod 'bash /tmp/nyx-ops/install-update-schedule.sh /tmp/nyx-ops'
```

Проверка расписания:

```bash
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer \
  nyx-docker-engine-update.timer nyx-containers-update.timer --no-pager
systemctl show nyx-containers-update.timer -p OnCalendar
```

Логи: `/var/log/nyx-updates/docker-engine.log`, `/var/log/nyx-updates/containers.log`.
Письма — на `furi_wave@mail.ru` через тот же `sendmail`-шим, что и у `unattended-upgrades`.

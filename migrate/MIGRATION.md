# Миграция NYX Panel: 31.76.8.29 → 87.120.186.100

Дата: 2026-08-17
Домен: `panel.kuban-forum.ru`
Статус: **миграция завершена** (2026-08-17, ~15:20 UTC): панель и sleep переехали, DNS переключён, все сервисы и клиенты работают.

## Суть

«Просто поставить панель заново + пересоздать юзеров» **сломает все клиентские конфиги**, потому что в конфиги юзеров зашиты серверные секреты (REALITY-ключи, obfs-пароль Hy2, AWG-ключи, crypto-key olcRTC, пароли Naive/Trojan/Mieru). Поэтому миграция = **копирование состояния сервера**, а не пересоздание.

## Что мигрируется

| Компонент | Пути |
|-----------|------|
| Панель + БД | `/opt/proxy-panel/` (app.py, collector.py, panel.db, templates, static) |
| Юзеры/конфиги | `/root/proxy_users/` + `.registry` |
| Менеджер | `/root/proxy_manager.sh` |
| VLESS/Xray | `/usr/local/etc/xray/config.json`, `/etc/xray/users.json` |
| Hysteria 2 | `/etc/hysteria/config.yaml` |
| Naive (sing-box) | `/etc/sing-box/config.json` |
| Trojan | `/etc/sing-box/trojan_users.json`, `/etc/trojan-go/config.json` |
| Mieru | `/etc/mita/server.json` **+ `/etc/mita/server.conf.pb` (protobuf!)** |
| olcRTC | `/etc/olcrtc/server.yaml`, `/etc/olcrtc/users.json` |
| AmneziaWG | `/etc/amnezia/amneziawg/awg0.conf` |
| Сертификаты | `/etc/proxy-certs/`, caddy LE `/var/lib/caddy/caddy/certificates/.../panel.kuban-forum.ru/` |
| Бинарники | `/usr/local/bin/{xray,sing-box,caddy,hysteria,olcrtc,trojan-go}`, `/usr/bin/{mita,awg,awg-quick}` |
| systemd-юниты | `/etc/systemd/system/*.service` **+ `/usr/lib/systemd/system/awg-quick@.service`, `awg-quick.target`** |
| Cron | `/root/crontab.txt` |

## Шаг 0. Проверки перед миграцией

- [x] Новый сервер: чистый Debian 13 (trixie) x86_64, root, порты свободны (87.120.186.100, 99GB/15GB RAM)
- [x] Доступ к DNS kuban-forum.ru
- [x] Инвентарь старого сервера (сервисы, юзеры, ключи, порты)

## Шаг 1. Запаковать состояние со старого сервера (31.76.8.29)

```bash
pscp -pw master2000 migrate/pack_old.sh root@31.76.8.29:/root/pack_old.sh
plink -pw master2000 root@31.76.8.29 "bash /root/pack_old.sh"
# Результат: /root/nyx-migrate-20260817.tar.gz (303 234 149 байт, 226 файлов)

# Перенести на новый сервер напрямую (быстрее, чем через локальную машину).
# На новом сервере выполнить (нужен пароль старого сервера):
sshpass -p '<пароль_нового>' scp -P 22 root@31.76.8.29:/root/nyx-migrate-20260817.tar.gz /root/
```
✅ Выполнено. Хэш архива на обоих серверах совпал: `834d2f2622f14c51743f390a5c7c5beb`.

## Шаг 2. Развернуть на новом сервере (87.120.186.100)

```bash
pscp -pw <пароль_нового> migrate\apply_new.sh root@87.120.186.100:/root/apply_new.sh
plink -pw <пароль_нового> root@87.120.186.100 "bash /root/apply_new.sh /root/nyx-migrate-20260817.tar.gz 87.120.186.100"
```
✅ Выполнено (3 запуска, см. «Известные проблемы»). Все 9 сервисов active.

## Шаг 3. Проверить на новом сервере ДО переключения DNS

✅ Выполнено. Итог:
- `https://panel.kuban-forum.ru/self/login` (резолв на 127.0.0.1) — 200, логин admin → 302
- Юзеры в БД: Alexander, Julia, Katya, Merlin, Silky, test, admin
- Прослушка: tcp 4433/8443/9443/444-448/5000, udp 30000/39743
- Cron: collector.py + service-watchdog.sh каждые 5 мин
- Все сервисы `enabled` (автостарт после reboot)

## Шаг 4. Переключить A-запись

- [x] `panel.kuban-forum.ru` A → `87.120.186.100` (проверено через 8.8.8.8 и 1.1.1.1: `https://panel.kuban-forum.ru/self/login` → 200)
- [x] `sleep.kuban-forum.ru` A → `87.120.186.100` (уже указывала; sleep переехал на новый prod — см. «sleep.kuban-forum.ru»)
- [x] Дождаться распространения: `nslookup panel.kuban-forum.ru`

## Шаг 5. Финальная проверка (после DNS)

- [x] `https://panel.kuban-forum.ru/self/login` — 200, вход под admin
- [x] В панели видны юзеры: Alexander, Julia, Katya, Merlin, Silky, test
- [x] Каждый протокол работоспособен (vless :4433, hy2 :30000, naive :8443, mieru :444-448, trojan :9443, awg/olcrtc :39743)
- [x] `systemctl status` всех сервисов: active
- [x] `https://sleep.kuban-forum.ru/` — работает на новом (см. «sleep.kuban-forum.ru»)

## Шаг 6. Обновить локальный .env

✅ Уже сделано: `SERVER_IP=87.120.186.100`, `PANEL_URL=https://panel.kuban-forum.ru/self/login`, `MIERU_IP=87.120.186.100`, `OLRTC_ICE=ws://panel.kuban-forum.ru:30001/ice`, `OLRTC_ROOM_URL=https://meet.egovm.ru/panel.kuban-forum.ru`.

## Известные проблемы (исправлены в ходе миграции)

1. **install.sh падал на сетевом таймауте** при сборке Caddy (Go-модуль с Google storage) → повторный запуск прошёл (кэш модулей тёплый).
2. **install.sh умирал на Шаге 9** (crontab): пайплайн `(crontab -l 2>/dev/null; ...) | sort -u | crontab -` падал из-за `set -euo pipefail`, когда crontab пуст → в `apply_new.sh` добавлены `|| true` и `crontab -l ... || true`.
3. **rsync не был установлен** install.sh → `apt-get install rsync` вручную.
4. **Порядок chown/создания юзеров в apply_new.sh**: chown'ы сертификатов выполнялись ДО создания юзеров → молча проваливались (`|| true`). Исправлено вручную на сервере:
   - `/etc/proxy-certs` → `root:hysteria` 750, файлы `hysteria:hysteria` 640
   - `/var/lib/caddy` → `caddy:nyxcerts` 2750 (рекурсивно, dirs 2750)
   - юзер `olcrtc` создан (`useradd -r -M -g olcrtc`)
   - `/var/lib/olcrtc/data` → `olcrtc:olcrtc`
   - `/etc/olcrtc/{server.yaml,users.json}` → `root:olcrtc` 640
   - ⚠️ **В apply_new.sh этот баг НЕ исправлен** — chown-блок надо перенести в шаг 3/6 (после создания юзеров).
5. **mita не стартовал**: «no user found». Бинарник читает protobuf `/etc/mita/server.conf.pb`, а не JSON. Скопирован `server.conf.pb` со старого сервера (md5 совпал), перезапущен → active, слушает 444-448. ⚠️ Добавить в pack_old.sh: `tar -C / -czf ... etc/mita/server.conf.pb`.
6. **awg-quick@awg0 не стартовал**:
   - юниты `awg-quick@.service`/`awg-quick.target` не попали в пакет (лежат в `/usr/lib/systemd/system/`) → скопированы вручную. ⚠️ Добавить в pack_old.sh.
   - `awg setconf` → «Invalid argument»: install.sh собрал модуль amneziawg **3.1.20260812** из GitHub master (в `/usr/src/amneziawg-1.0.0`), а клиенты настроены на **1.0.20260611**. Решение: скопированы исходники `/usr/src/amneziawg-1.0.0` со старого, `dkms remove/add/build/install` с настоящей версией 1.0.0 → awg0 active, 10.9.9.1/24.
7. **AmneziaWG клиенты подключались, но трафик не шёл** (Merlin: handshake свежий, rx/tx росли, но интернета нет): UFW на новом сервере имел политику **`deny (routed)`** → весь форвардинг через awg0 блокировался (`ufw-reject-forward`). На старом было `allow (routed)`. Лечение: `ufw default allow routed` (пишется в `/etc/default/ufw`, переживает reboot). Заодно проверено:
   - `net.ipv4.ip_forward=1` включается автоматически через `PostUp` в `awg0.conf` (persist не требуется отдельно);
   - MASQUERADE добавляется тем же PostUp;
   - после фикса коллектор стал корректно писать awg-трафик (проверено на Merlin: дельты в `traffic_log`/`daily_traffic`, `awg_last.json`).
   - ⚠️ В `apply_new.sh` НЕ учтено — при будущей миграции на новом сервере выполнить `ufw default allow routed` (или скопировать `/etc/default/ufw` со старого).
8. **Frontend sleep собирался с неверным API URL**: у меня нет файла `frontend/.env`, поэтому при сборке сработал фолбэк `VITE_API_BASE_URL || 'https://sleep-test.kuban-forum.ru'` (`frontend/src/lib/api.ts`) → «Network Error» при входе и показ «Перейти на Pro» (биллинг не грузился → `sub_type=free`). На старом prod в dist был зашит `https://sleep.kuban-forum.ru`. Лечение: создать `frontend/.env` с `VITE_API_BASE_URL=https://sleep.kuban-forum.ru` и пересобрать (`npm run build`). ⚠️ Зафиксировать: при развёртывании sleep **обязательно** создавать `frontend/.env`, иначе фронт указывает на несуществующий `sleep-test.kuban-forum.ru`.

## Что НЕ переносится / отдельные приложения

- Внешний Jitsi `meet.egovm.ru` — остаётся как есть, от IP сервера не зависит.

## Миграция sleep.kuban-forum.ru (вторая фаза, 2026-08-17)

Стек на старом сервере: FastAPI backend (uvicorn :8000) + LLM-сервис (uvicorn :8001) + Celery worker + Postgres 17 с pgvector (БД `innercore`) + Redis + фронт (vite build) + Caddy-блок. Развёрнут **с нуля** из git, данные перенесены целиком.

### Что сделано
1. **Git**: клонирован `https://github.com/smartor777-sketch/sleep.git` в `/srv/sleep-prod/backend`, checkout `e981d67` (тот же коммит, что на проде).
2. **БД**: `pg_dump -Fc innercore` со старого (241KB, хэш `7be6b104b5fd0605e160ce50470ec5ef`) → `pg_restore` на новом. Юзер/БД `innercore` (`inn3rc0re_prod_2026`), pgvector 0.8.0. Идентична старому: 16 таблиц, админ `sleep@kuban-forum.ru`, тест `test.sleep@innercore.example.com` (19 снов), `wowaf1973@gmail.com` (3 сна) и др.
3. **Python 3.13.5 venv**: `backend/.venv` (fastapi, sqlalchemy, asyncpg, celery, weasyprint, faster-whisper, umap, pgvector...) + `llm_service/.venv`. Потребовались системные пакеты: `libpango-1.0-0 libpangoft2-1.0-0 libcairo2 libgdk-pixbuf-2.0-0 shared-mime-info ffmpeg`.
4. **Postgres 17 + pgvector + Redis**: `apt install postgresql-17-pgvector redis-server` (Debian 13: PG 17.11, vector 0.8.0 — те же версии).
5. **Фронт**: `npm ci && npm run build` → `frontend/dist` (2.7MB).
6. **systemd**: `innercore-prod.service`, `innercore-llm.service`, `celery-prod.service` (+ `.d/memory.conf` с autoscale 2,1) — дословно как на старом.
7. **Caddyfile**: добавлен блок `sleep.kuban-forum.ru` (api→:8000, dist, no-cache). Caddy перезагружен, конфиг валиден.
8. **A-запись**: `sleep.kuban-forum.ru` уже указывала на 87.120.186.100.

### Проверки
- `https://sleep.kuban-forum.ru/` → 200 (фронт «InnerCore — атлас вашего бессознательного»)
- `/api/auth/login` POST → JSON 426 (штатный версионный guard), **идентичен** старому серверу
- `/docs` → 200; сервисы innercore-prod/llm/celery → active; `Database initialized` в логах
- Celery worker: «ready.», redis PONG

### Замечания
- S3 (`S3_ENDPOINT=http://127.0.0.1:9000`) на старом сервере **не слушает** (:9000 закрыт) — MinIO там не запущен; приложение работает без него (или лениво инициализирует). На новом не поднимался.
- Telegram-бот (`backend/bot/`) на старом проде **не запущен** — не переносился.
- ⚠️ Если будете останавливать старый сервер — Celery на новом должен успеть добрать задачи из Redis; квитать задачи из старого Redis не нужно (он отдельный).

## Откат

Старый сервер продолжает работать, пока не переключён DNS панели. Для отката — вернуть A-записи: `panel.kuban-forum.ru` → 31.76.8.29, `sleep.kuban-forum.ru` → 31.76.8.29.
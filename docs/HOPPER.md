# Hopper — экспериментальная нода (multi-hop L3-VPN)

> **СТАТУС: EXPERIMENTAL. В продакшен не включается.**
> Документ описывает исследовательскую установку [`ZonD80/hopper`](https://github.com/ZonD80/hopper)
> на dev-стенде, hardening ограниченного sudo-доступа и результаты теста сетевой изоляции.
> В панель NYX Hopper **не интегрирован** (архитектурно не ложится в модель «юзер + протокол»).
>
> **Все чувствительные данные в этом документе заменены заглушками** (`<...>`, `CHANGE_ME`).
> Реальные пароли/ключи/host-key fingerprints в репозиторий не попадают.

---

## 1. Что это

`hopperd` — multi-hop L3-VPN поверх SSH. В отличие от прокси-протоколов (VLESS/Hy2/AWG):

- Нет per-user QR / подписок / лимитов трафика — «юзеры» это устройства внутри overlay-подсети.
- Трафик считает сам демон (`~/.hopper/.../hopper.log`), а не панель.
- Управляется мобильным приложением (iOS App Store / Android Google Play), которое коннектится по SSH
  и поднимает `hopperd` при подключении. **systemd-сервиса нет by design** — демон живёт, пока держится
  сессия приложения.
- `hopperd` слушает только loopback, доступ — через SSH-форвардинг.

Из-за этой модели в панель NYX Hopper **не интегрируется**. Стоит на стенде как отдельная нода.

### Предпосылки хоста

- `x86_64`, `/dev/net/tun`
- `ip` (iproute2), `iptables`, `python3` (зависимости stdlib-only, venv не нужен)
- открытый `SSH:22`

---

## 2. Установка

Штатный инсталлятор скачивает готовый бинарь из GitHub-релиза (сборка Go не нужна):

```bash
# на хосте, под root
git clone https://github.com/ZonD80/hopper
cd hopper
./install.sh --configure
```

Что ставится:

- `hopperd-linux-amd64` (~4.2 МБ, релиз v2.0.0) — Go-бинарь демона.
- `hopperctl` — Python CLI-обёртка (`hopper.cli`).
- ключи `ed25519` в `~/.hopper/`, обновляется `authorized_keys`.

### Управление: `hopperctl`

```bash
# статус
hopperctl status

# поднять цепочку (роль exit — выходная нода)
hopperctl start --chain-id <UUID> --role exit --addr <A.B.C.D> --index <N>

# роль relay — промежуточный хоп
hopperctl start --chain-id <UUID> --role relay --addr <A.B.C.D> --index <N>

# остановить
hopperctl start --chain-id <UUID> --role exit --addr <A.B.C.D> --index <N> --stop-only
```

Параметры overlay/порта/TUN выводятся детерминированно из `chain-id` (октет = хэш от UUID):

| Параметр | Значение |
|----------|----------|
| overlay  | `10.64.{octet}.0/24` |
| listen_port | `7400 + octet` |
| TUN iface | `hopper_<первые 8 символов chain-id>` |
| addr на TUN | `<addr>/32` + route `10.64.{octet}.0/24 dev <tun>` |

---

## 3. Root vs не-root

**TUN требует root.** `ip tuntap add` даёт `ioctl(TUNSETIFF): Operation not permitted` даже при
`setcap cap_net_admin` на `ip` — file-capabilities не наследуются не-root процессом при таком вызове.
**Полностью не-root Hopper поднять нельзя.**

Компромисс на стенде: отдельный **не-root юзер `hopper`**, которому даётся root **только на один
управляющий бинарь** через `sudo`, а не на shell/файлы. Приложение коннектится как `hopper`.

Root-деплой (`user root`) остаётся запасным вариантом.

---

## 4. Hardening ограниченного sudo (важно!)

### Почему наивный вариант небезопасен (security theater)

Если код Hopper лежит в домашней папке юзера `hopper` (`/home/hopper/hopper`, владелец `hopper`),
а sudo-правило указывает на файл там же — юзер `hopper` может **перезаписать сам sudo-таргет /
python-код / бинарь `hopperd`** (всё это исполняется как root) → тривиальная эскалация в полный root
(классическая дыра sudo: *writable target*). Проверено фактически на стенде.

### Правильная схема (применена и проверена)

Весь исполняемый как root код вынесен в **root-owned** `/opt/hopper`, домашняя папка `hopper`
кода не содержит. **Код (root, ro для hopper) отделён от данных (hopper-owned).**

```bash
# 1. код -> /opt/hopper, root-owned, недоступен hopper на запись
mv /home/hopper/hopper /opt/hopper
chown -R root:root /opt/hopper
chmod -R go-w /opt/hopper

# 2. capability на демон per-file (системные ip/iptables НЕ трогаем)
setcap cap_net_admin+ep /opt/hopper/dist/hopperd-linux-amd64
```

**`/opt/hopper/hopperctl.bin`** — root-owned launcher. `PYTHONSAFEPATH=1` блокирует import-hijack
через подсунутый `os.py` в текущем каталоге:

```bash
#!/usr/bin/env bash
cd /opt/hopper
export HOPPER_DIR=/opt/hopper
export PYTHONPATH=/opt/hopper
export PYTHONSAFEPATH=1
exec /usr/bin/python3 -m hopper.cli "$@"
```

**`/usr/local/bin/hopperctl`** — root-owned обёртка в `PATH`: не-root уходит в sudo на фиксированный
бинарь:

```bash
#!/usr/bin/env bash
if [ "$(id -u)" -eq 0 ]; then
  exec /opt/hopper/hopperctl.bin "$@"
else
  exec sudo -n /opt/hopper/hopperctl.bin "$@"
fi
```

**`/etc/sudoers.d/hopper`** — sudo только на один root-owned бинарь, `HOME` сохраняется, чтобы
данные писались в `/home/hopper/.hopper`:

```
hopper ALL=(root) NOPASSWD: /opt/hopper/hopperctl.bin
Defaults:hopper env_keep += "HOME"
```

```bash
chmod 0440 /etc/sudoers.d/hopper
visudo -cf /etc/sudoers.d/hopper   # проверка синтаксиса
```

### Разделение код / данные

| Что | Путь | Владелец | Права для hopper |
|-----|------|----------|-----------------|
| код, launcher, бинарь демона | `/opt/hopper` | root | read-only |
| обёртка в PATH | `/usr/local/bin/hopperctl` | root | read-only |
| sudo-правило | `/etc/sudoers.d/hopper` | root | нет |
| ключи, чейны, `registry.json`, `hopper.json` | `/home/hopper/.hopper` | hopper | rw |

`hopperd` запускается как root, но читает из `.hopper` только **сетевые параметры** (addr / overlay /
port / next-host), а не исполняемые команды.

### Верификация hardening (пройдено на стенде)

- юзер `hopper` **не может** писать `hopperctl.bin`, `cli.py`, `hopperd-linux-amd64`,
  `/usr/local/bin/hopperctl` (все `ro`);
- **не может** подменить каталоги `/opt`, `/opt/hopper` (`ro-dir`);
- import-hijack через cwd `os.py` заблокирован (`PYTHONSAFEPATH=1`);
- при этом под `hopper`: `hopperctl status` и `start` работают (`ready:true, nat:true`), `hopperd`
  бежит от root из `/opt/hopper`, ключи/конфиг остаются в `/home/hopper/.hopper`.

---

## 5. Тест сетевой изоляции

Проверено кодом (`routes.go` / `session.go` / `nat_linux.go` / `tun_linux.go`) + снятым состоянием
ядра при **двух поднятых цепочках**.

### Что делает `hopperd` с ядром (измерено)

```
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0        # <-- ставится host-wide
net.ipv4.conf.default.rp_filter = 0
```

```
# TUN каждой цепочки
<addr>/32  +  route 10.64.{octet}.0/24 dev hopper_<chain>

# iptables filter
-P FORWARD ACCEPT
-A FORWARD -i hopper_<chain> -j ACCEPT
-A FORWARD -o hopper_<chain> -j ACCEPT

# iptables nat (только интернет-выход)
-A POSTROUTING -s 10.64.{octet}.0/24 -o <ens3> -j MASQUERADE
```

### (a) Клиенты одной цепочки — НЕ изолированы

Пакет от клиента A к overlay-IP клиента B на exit-ноде заворачивается `ViaTun` → пишется в TUN →
ядро (`/24 dev tun`, `ip_forward=1`, `FORWARD -o tun ACCEPT`) отправляет обратно в тот же TUN →
`tunReader` находит сессию B в registry → доставляет B. **Клиенты видят друг друга по overlay-IP.**

### (b) Соседние цепочки на одном хосте — НЕ изолированы

Пакет `10.64.X.2 → 10.64.Y.3` идёт по default-route чейна A в `hopper_A` → ядро видит
`10.64.Y.0/24 dev hopper_B` → правило `FORWARD -i hopper_A -j ACCEPT` пропускает → уходит в `hopper_B`
→ демон B доставляет. Путь **двунаправленный**. Cross-chain masquerade нет, поэтому B видит реальный
src `10.64.X.2`.

### Вывод

Multi-chain даёт только **номинальное** L3-разделение (разные подсети/TUN), но **не enforced-изоляцию**
на общем хосте: `ip_forward=1` + permissive `FORWARD ACCEPT` + `rp_filter=0` делают достижимыми и
клиентов внутри цепочки, и соседние цепочки. **Настоящая изоляция групп — только на разных VPS.**

### Побочные находки (безопасность)

1. **`rp_filter=0` host-wide** — `hopperd` при NAT-сетапе ослабляет anti-spoofing для всего сервера,
   не только для overlay.
2. **Утечка iptables-правил** — `hopperctl ... --stop-only` не удаляет FORWARD/MASQUERADE-правила;
   со временем таблица растёт stale-записями для несуществующих TUN/подсетей.

### Ручная очистка stale-правил

```bash
# остановить демоны
pkill -f 'hopperd-linux-amd64'

# удалить все hopper_* FORWARD-правила
while iptables -S FORWARD | grep -q 'hopper_'; do
  spec=$(iptables -S FORWARD | grep -m1 'hopper_' | sed 's/^-A FORWARD //')
  iptables -D FORWARD $spec
done

# удалить все 10.64.x MASQUERADE-правила
while iptables -t nat -S POSTROUTING | grep -q '10\.64\.'; do
  spec=$(iptables -t nat -S POSTROUTING | grep -m1 '10\.64\.' | sed 's/^-A POSTROUTING //')
  iptables -t nat -D POSTROUTING $spec
done
```

---

## 6. Multi-user (как раздать нескольким людям)

Per-user конфигов / подписок / лимитов трафика **нет** (это не VLESS). Два пути:

- **Multi-device на одну цепочку**: overlay `/24` → пул `10.64.{octet}.2–.254` → до ~250 клиентов
  одновременно; каждому уникальный адрес по lease (обновляется, пока подключён; протухает ~1 час).
  На практике — раздать один профиль сервера нескольким людям.
- **Multi-chain**: несколько независимых цепочек, у каждой свой UUID → свой overlay/порт/TUN;
  один VPS может быть entry в одной и exit в другой. **Изоляция групп здесь номинальная** (см. §5) —
  на одном хосте не enforced.

---

## 7. Итоговая оценка

Организация нескольких клиентов на Hopper **работоспособна и в целом безопасна**, но «стены тонкие»:
запаса прочности на многослойную защиту нет —

- единственный слой iptables `ACCEPT` + host-wide `rp_filter=0`,
- нет per-user лимитов / учёта трафика,
- утечка правил при остановке,
- TUN требует root (полный non-root невозможен).

Поэтому Hopper помечен как **experimental**: держим как исследовательскую ноду на стенде,
**в продакшен пока не включаем**, в панель NYX не интегрируем.

---

## Приложение: ресурсы стенда (заглушки)

> Реальные значения — в приватных заметках, НЕ в репозитории.

```
host          : <STEND_IP>  (<STEND_HOSTNAME>)
ssh user      : hopper       (не-root, ограниченный sudo)
ssh password  : CHANGE_ME
host-key (SHA256): CHANGE_ME
code dir      : /opt/hopper           (root-owned)
data dir      : /home/hopper/.hopper  (hopper-owned)
```

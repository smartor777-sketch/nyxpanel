# AmneziaWG: DKMS и обновления ядра

Модуль `amneziawg` собирается DKMS под конкретную версию ядра. После
обновления ядра — в том числе когда хостер перезагружает VPS с новым
kernel — модуль для нового ядра может отсутствовать. Тогда
`awg-quick@awg0` падает, интерфейс `awg0` не создаётся, порт `39743`
не слушает, и все клиенты AmneziaWG остаются без VPN.

Документ дополняет [`AMNEZIAWG-3.1.md`](AMNEZIAWG-3.1.md) (параметры
протокола) и [`REQUIREMENTS.md`](REQUIREMENTS.md) (версии модуля и tools).

---

## 1. Симптомы

В `systemctl status awg-quick@awg0`:

```
[#] ip link add awg0 type amneziawg
Error: Unknown device type.
Unable to access interface: Protocol not supported
[#] ip link delete dev awg0
Cannot find device "awg0"
Failed to start awg-quick@awg0.service
```

Проверка модуля:

```bash
lsmod | grep amneziawg          # пусто
modprobe amneziawg
# modprobe: FATAL: Module amneziawg not found in directory
# /lib/modules/6.12.116+deb13-amd64
```

При этом сам сервис может быть `enabled` — он падает именно на старте,
потому что ядро не знает тип устройства `amneziawg`.

---

## 2. Диагностика

```bash
# какое ядро реально загружено
uname -r

# под какие ядра собран модуль
dkms status
# amneziawg/3.1.20260906, 6.12.115+deb13.1-amd64: installed
# (строки для текущего ядра нет — это и есть причина)

# есть ли файл модуля для текущего ядра
ls /lib/modules/$(uname -r)/updates/dkms/ | grep amneziawg

# установлены ли headers для текущего ядра
ls -d /lib/modules/$(uname -r)/build

# состояние сервиса
systemctl status awg-quick@awg0 --no-pager -n 20
```

Если `dkms status` не содержит строки с `$(uname -r)`, а
`/lib/modules/$(uname -r)/updates/dkms/amneziawg.ko.xz` отсутствует —
модуль не собран под текущее ядро.

---

## 3. Исправление

```bash
export DEBIAN_FRONTEND=noninteractive

# 1. headers для текущего ядра
apt-get update
apt-get install -y linux-headers-$(uname -r)

# 2. сборка и установка модуля под текущее ядро
#    (если headers-only install уже запустил DKMS autoinstall — команда
#     ответит "already installed, skip", это нормально)
dkms install amneziawg/3.1.20260906 -k "$(uname -r)"

# 3. загрузка модуля
modprobe amneziawg
lsmod | grep amneziawg

# 4. поднять интерфейс
systemctl start awg-quick@awg0
systemctl is-active awg-quick@awg0
ip -br link show awg0
```

Проверка, что 3.1-параметры применились:

```bash
awg show awg0
# должны быть header protection key, random trailers: on,
# disable cookies: on, i1, диапазоны таймингов
```

---

## 4. Профилактика

Одного `dkms install` недостаточно: при следующем обновлении ядра история
повторится. Нужны три вещи.

### 4.1. Meta-пакет headers

```bash
apt-get install -y linux-headers-amd64
```

`linux-headers-amd64` тянет headers для default-ядра при каждом обновлении.
DKMS-хук в `/etc/kernel/header_postinst.d/dkms` собирает модуль
автоматически, как только headers установлены.

Без этого meta-пакета ядро может обновиться, а headers — нет, и DKMS
молча останется без новой версии.

### 4.2. Автозагрузка модуля

```bash
cat /etc/modules-load.d/amneziawg.conf
# amneziawg
```

`systemd-modules-load.service` загружает модуль на раннем этапе boot,
до старта `awg-quick@awg0`.

### 4.3. Автозапуск интерфейса

```bash
systemctl is-enabled awg-quick@awg0
# enabled
```

Если сервис `disabled`, после перезагрузки интерфейс не поднимется даже
при загруженном модуле.

---

## 5. Проверка после обновления ядра

- [ ] `uname -r` — ожидаемая версия
- [ ] `dkms status` содержит строку для текущего ядра
- [ ] `lsmod | grep amneziawg` — модуль загружен
- [ ] `systemctl is-active awg-quick@awg0` — active
- [ ] `ip -br link show awg0` — UP
- [ ] `awg show awg0` — 3.1-параметры на месте
- [ ] `awg show awg0 latest-handshakes` — у активных пиров свежий handshake
- [ ] `dpkg -l | grep linux-headers-amd64` — meta-пакет установлен

Сквозная проверка — с клиента:

```bash
ping -c 3 10.20.20.1
curl --interface <client_ip> https://api.ipify.org
```

---

## 6. Откат

Старое ядро с уже собранным модулем остаётся в системе. Если новое ядро
проблемное, можно загрузиться в старое через GRUB — модуль там уже есть.
Посмотреть установленные ядра:

```bash
dpkg -l | grep linux-image-6
```

Альтернатива — пересобрать модуль под проблемное ядро (раздел 3).

---

## 7. Случай на стенде dev (2026-11-09)

- Хостер перезагрузил VPS в **04:00**; загрузилось ядро
  **`6.12.116+deb13-amd64`** вместо `6.12.115+deb13.1-amd64`.
- DKMS имел модуль только для `6.12.115`:

```
amneziawg/3.1.20260906, 6.12.115+deb13.1-amd64: installed (Original modules exist)
```

- `awg-quick@awg0` упал с `Unknown device type` / `Protocol not supported`.
- Исправление: `linux-headers-6.12.116+deb13-amd64`, DKMS autoinstall,
  `modprobe amneziawg`, `systemctl start awg-quick@awg0`.
- Дополнительно установлен `linux-headers-amd64`.
- После исправления: `awg0` UP, все 3.1-параметры (включая QUIC-прелюд
  `I1`), 3 пира, сквозной тест с клиента прошёл.

---

## 8. Связанные файлы

| Что | Где |
|---|---|
| Параметры AmneziaWG 3.1 | [`AMNEZIAWG-3.1.md`](AMNEZIAWG-3.1.md) |
| Версии модуля и tools | [`REQUIREMENTS.md`](REQUIREMENTS.md) |
| Серверный конфиг и пиры | [`SERVER_CONFIG.md`](SERVER_CONFIG.md) |
| DKMS-исходники на стенде | `/usr/src/amneziawg-3.1.20260906/` |

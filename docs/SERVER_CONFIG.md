# Серверная конфигурация

> Дата: 2026-07-17
> Сервер: `31.76.8.29` (MyServer-1.play2go.cloud)
> Домен: `76t05pyu.ikill.baby`

---

## Стек протоколов

| Протокол | Статус | Порт |
|----------|--------|------|
| VLESS+XHTTP+REALITY | ✅ active | `443` |
| Hysteria 2 | ✅ active | `30000` |
| Mieru | ✅ active | `444-448` |
| olcRTC (Jitsi) | ✅ active | — (через Jitsi Meet) |
| Caddy (Naive-прокси, панель) | ✅ active | `80`, `8443` |
| AmneziaWG | ✅ active | `39743` (UDP) |
| NaiveProxy (Caddy forward_proxy) | ✅ active | `8443` |

---

## VLESS+XHTTP+REALITY

**Сервис:** `xray.service`
**Порт:** `443`
**Network:** `xhttp`, path `/vless`
**Security:** `reality`
**SNI:** `1.1.1.1`
**Short ID:** `2e30b986cabb4bca`
**Private Key:** `aGd92LnG7GGAkFq-n23apez8SG_bRJlDfn75yTlK6Wc`
**Public Key:** (вычисляется из private)

Формат URI:
```
vless://UUID@76t05pyu.ikill.baby:443?security=reality&type=xhttp&path=%2Fvless&sni=1.1.1.1&fp=chrome&pbk=...&sid=2e30b986cabb4bca&spx=%2Fdns-query%2F#NAME
```

---

## Hysteria 2

**Сервис:** `hysteria-server.service`
**Порт:** `30000`
**Obfs:** `salamander`, пароль `c8fb2a6e302b52f06a05c3455a5927a6`
**TLS:** `/etc/proxy-certs/fullchain.pem`
**Masquerade:** `https://zarazaex.xyz/`
**Auth:** userpass

---

## AmneziaWG

**Сервис:** `awg-quick@awg0.service`
**Интерфейс:** `awg0` (UP)
**Порт:** `39743` (UDP)
**Сеть:** `10.9.9.0/24`

**Пиры:**
- test — `10.9.9.2`
- Merlin — `10.9.9.3`
- Katya — `10.9.9.4`

**Конфиг:** `/etc/amnezia/amneziawg/awg0.conf`

---

## Mieru

**Сервис:** `mita` (PID 2024)
**Порты:** `444-448`

---

## olcRTC

**Сервис:** `olcrtc.service`
**Бинарь:** `/root/pj/olcrtc/build/olcrtc-linux-amd64`
**Конфиг:** `/root/.config/olcrtc/server.yaml`
**Режим:** `srv` + `auth.provider: jitsi`
**Комната:** `https://meet.egovm.ru/pxy-76t05pyu.ikill.baby`
**Ключ:** `2967bab5e92bb2c9ceef2e0e9b7b65d1dabca7d7b2db8c005250a591d2ce4b31`
**Транспорт:** `datachannel`
**Auth:** users_file (`/etc/olcrtc/users.json`)

**Пользователи:**
| Имя | Пароль |
|-----|--------|
| Katya | `katya_olc_2024` |
| test | `1086403b6dfc7c62cd10e4c4` |
| Merlin | `8725d376b7a58b657a870400` |

**Формат olcbox URI:**
```
olcrtc://jitsi?datachannel&user={user}&pass={pass}@{ROOM}#{KEY}$pxy-olcrtc - {NAME}
```

**Формат YAML (клиент):**
```yaml
mode: cnc
auth:
  provider: jitsi
room:
  id: "https://meet.egovm.ru/pxy-76t05pyu.ikill.baby"
crypto:
  key: "2967bab5e92bb2c9ceef2e0e9b7b65d1dabca7d7b2db8c005250a591d2ce4b31"
claims:
  user: USERNAME
  pass: PASSWORD
net:
  transport: datachannel
socks:
  host: 127.0.0.1
  port: 1082
```

---

## Caddy (он же NaiveProxy)

**Сервис:** `caddy.service`
**Порт:** `:8443` (HTTPS) + `:80` (HTTP redirect)

**Модуль forward_proxy** (NaiveProxy):
- HTTP/SOCKS5 forward proxy с basicauth
- `https://76t05pyu.ikill.baby:8443/`
- Пользователи: `Merlin` (2 пароля), `pxy04d7`

**Маршруты:**
- `/` — forward proxy (basicauth) → `zarazaex.xyz`
- `/panel*` — basicauth `admin` → Flask на `127.0.0.1:5000`

---

## Web-панель

**Сервис:** `panel.service`
**URL:** `https://76t05pyu.ikill.baby:8443/panel/`
**Логин:** `admin` / `admin123`
**Бэкенд:** Python 3 + Flask (`/opt/proxy-panel/app.py`)
**Шаблон:** `/opt/proxy-panel/templates/index.html`
**Caddy basicauth:** `$2a$14$or1W8yhOEefhPzxI1ZhReu...` (bcrypt)

### Функции

- **Добавление пользователя** — создаёт папку и реестр
- **Добавление протокола** — вызывает `proxy_manager.sh add_{proto}_user {user}`
- **Удаление протокола** — вызывает `proxy_manager.sh remove_protocol {user} {proto}`
- **Удаление пользователя** — вызывает `proxy_manager.sh del_user {user}` (с полной зачисткой)
- **Скачивание конфига** — отдаёт файл из `proxy_users/{user}/{user}_{proto}.*`
- **QR-код** — отдаёт PNG из `proxy_users/{user}/{user}_{proto}.png`

### Протоколы в панели

| Ключ | Название | Файл конфига | Файл QR |
|------|----------|-------------|---------|
| `hy2` | Hysteria 2 | `{user}_hy2.json` | `{user}_hy2.png` |
| `awg` | AmneziaWG | `{user}_awg.conf` | `{user}_awg.png` |
| `naive` | NaiveProxy | `{user}_naive.json` | `{user}_naive.png` |
| `mieru` | Mieru | `{user}_mieru.json` | `{user}_mieru.png` |
| `olcrtc` | olcRTC | `{user}_olcrtc.yaml` | `{user}_olcrtc.png` |
| `vless` | VLESS+XHTTP+REALITY | `{user}_vless.uri` | `{user}_vless.png` |

### Интерфейс

Тёмная тема (GitHub Dark), таблица пользователей с колонками:
- Имя пользователя
- По каждому протоколу: `+` (активен) или `-` (не добавлен)
- Действия: кнопки `+` добавить / `-удалить`, `cfg` скачать конфиг, `qr` QR-код
- Красная кнопка `Delete User` с подтверждением

---

## proxy_manager.sh

**Путь:** `/root/proxy_manager.sh`
**Версия:** 0.8
**Язык:** Bash
**Зависимости:** `jq`, `yq`, `qrencode`, `awg`

### Параметры сервера (встроенные)

| Параметр | Значение |
|----------|----------|
| `SERVER_DOMAIN` | `76t05pyu.ikill.baby` |
| `BASE_DIR` | `/root/proxy_users` |
| `HY2_CONFIG` | `/etc/hysteria/config.yaml` |
| `AWG_CONFIG` | `/etc/amnezia/amneziawg/awg0.conf` |
| `NAIVE_CONFIG` | `/etc/caddy/Caddyfile` |
| `XRAY_CONFIG` | `/usr/local/etc/xray/config.json` |
| `MIERU_CONFIG` | `/etc/mita/server.json` |
| `OLRTC_USERS_FILE` | `/etc/olcrtc/users.json` |
| `OLRTC_ROOM_URL` | `https://meet.egovm.ru/pxy-76t05pyu.ikill.baby` |
| `OLRTC_CRYPTO_KEY` | `2967bab5e92bb2c9ceef2e0e9b7b65d1dabca7d7b2db8c005250a591d2ce4b31` |
| `VLESS_USERS_FILE` | `/etc/xray/users.json` |
| `VLESS_HOST` | `76t05pyu.ikill.baby` |
| `VLESS_PORT` | `443` |
| `VLESS_PUBLIC_KEY` | `iqmUrTnhYDcm-hhuGJaze6dTGNIcvyMOyYIN7LB4kU4` |
| `VLESS_SHORT_ID` | `2e30b986cabb4bca` |

### CLI-команды

```bash
bash /root/proxy_manager.sh add_user <username>
bash /root/proxy_manager.sh del_user <username>
bash /root/proxy_manager.sh add_hy2_user <username>
bash /root/proxy_manager.sh add_awg_user <username>
bash /root/proxy_manager.sh add_naive_user <username>
bash /root/proxy_manager.sh add_mieru_user <username>
bash /root/proxy_manager.sh add_olcrtc_user <username>
bash /root/proxy_manager.sh add_vless_user <username>
bash /root/proxy_manager.sh remove_protocol <username> <protocol>
bash /root/proxy_manager.sh list_users
```

### Что генерирует каждый протокол

| Протокол | Команда | Файлы в `proxy_users/{user}/` |
|----------|---------|-------------------------------|
| Hysteria 2 | `add_hy2_user` | `{user}_hy2.json`, `{user}_hy2.png` |
| AmneziaWG | `add_awg_user` | `{user}_awg.conf`, `{user}_awg.png`, `.awg_pubkey` |
| NaiveProxy | `add_naive_user` | `{user}_naive.json`, `{user}_naive.png` |
| Mieru | `add_mieru_user` | `{user}_mieru.json`, `{user}_mieru_standalone.json`, `{user}_nekobox.txt`, `{user}_mieru.png` |
| olcRTC | `add_olcrtc_user` | `{user}_olcrtc.yaml`, `{user}_olcrtc.uri`, `{user}_olcrtc.txt`, `{user}_olcrtc.png` |
| VLESS+XHTTP+REALITY | `add_vless_user` | `{user}_vless.uri`, `{user}_vless.png` |

### Логика удаления (`del_user`)

При удалении пользователя скрипт проходит по всем протоколам:
1. Удаляет запись из реестра (`.registry`)
2. Удаляет пир из AmneziaWG перезаписью конфига + `awg-quick down/up`
3. Удаляет `basic_auth` строку из Caddyfile + `systemctl reload caddy`
4. Удаляет пользователя из Mieru (JSON) + `mita apply/stop/start`
5. Удаляет запись из Hysteria 2 (userpass) + `systemctl restart hysteria-server`
6. Удаляет запись из olcRTC (`/etc/olcrtc/users.json`)
7. Удаляет UUID из VLESS (`/etc/xray/users.json`) + обновляет xray config + `systemctl restart xray`
8. Удаляет папку пользователя

### Интерактивное меню

При запуске без аргументов открывается меню:
```
=========================================
      🚀 ПРОКСИ-МЕНЕДЖЕР (v0.8) 🚀
=========================================
1. Добавить пользователя
2. Удалить пользователя
3. Список пользователей
4. Удалить конфигурацию протокола
-----------------------------------------
5. Добавить Hysteria 2 пользователю
6. Добавить AmneziaWG пользователю
7. Добавить NaiveProxy пользователю
8. Добавить Mieru пользователю
9. Добавить olcRTC пользователю
10. Добавить VLESS+XHTTP+REALITY пользователю
-----------------------------------------
0. Выход
```

---

## Пользователи

| Имя | Протоколы | Где хранятся |
|-----|-----------|-------------|
| Merlin | hy2, awg, mieru, naive, olcrtc, vless | `/root/proxy_users/Merlin/` |
| Katya | awg, olcrtc | `/root/proxy_users/Katya/` |
| test | awg, olcrtc, vless | `/root/proxy_users/test/` |
| vless | vless | `/root/proxy_users/vless/` |

---

## Android-сборка

**olcboxME** — пропатченная версия с claims-авторизацией:
- `applicationId: org.olcbox.me`
- Обновления: `github.com/smartor777-sketch/olcbox-me`
- Подпись: самоподписанный сертификат
- Бинарь: `olcbox-me-release.apk` (37 MB)

**Windows CLI:**
- `olcrtc-windows-amd64.exe` (44 MB) — кросскомпилирован с `GOOS=windows`

---

## Пути к исходникам

| Путь | Назначение |
|------|-----------|
| `/root/pj/olcrtc/` | olcRTC (форк с claims) |
| `/root/pj/olcbox/` | olcbox (KMP Android + Desktop) |
| `/opt/proxy-panel/` | Flask-панель |
| `/root/proxy_manager.sh` | Скрипт управления |
| `/etc/caddy/Caddyfile` | Caddy-конфиг |
| `/etc/hysteria/config.yaml` | Hysteria 2 |
| `/usr/local/etc/xray/config.json` | Xray VLESS |
| `/root/.config/olcrtc/server.yaml` | olcRTC сервер |
| `/etc/olcrtc/users.json` | olcRTC users |
| `/etc/proxy-certs/` | TLS-сертификаты |

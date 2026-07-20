# Proxy Protocols

## Активные протоколы

| Протокол | Порт | Статус |
|----------|------|--------|
| VLESS+XHTTP+REALITY | 443 | active |
| Hysteria 2 | 30000 | active |
| Mieru | 444-448 | active |
| olcRTC (Jitsi) | via Jitsi Meet | active |
| Caddy (NaiveProxy + Panel) | 80, 8443 | active |
| AmneziaWG | 39743 (UDP) | active |

## Управление

Основной скрипт: `server/proxy_manager.sh` (v0.8)

CLI-режим:
- `bash server/proxy_manager.sh add_user <protocol> <username>`
- `bash server/proxy_manager.sh del_user <protocol> <username>`
- `bash server/proxy_manager.sh list_users [protocol]`
- `bash server/proxy_manager.sh status`

## Пользователи

| Пользователь | Протоколы |
|-------------|-----------|
| Merlin | hy2, awg, vless, naive, mieru, olcrtc |
| Katya | awg, olcrtc |
| test | awg, olcrtc, vless |
| vless | vless |

## Конфиги

- Xray: `config/tmp_xray_v4.json` (XHTTP+REALITY+Sniffing, production)
- Hysteria2: управляется через `server/proxy_manager.sh`
- olcRTC: `bin/Merlin_olcrtc.yaml` (пример клиентского конфига)
- Xray V2/V3 варианты в `config/` для экспериментов

## Принципы

- VLESS — только с REALITY (no TLS visibility)
- Hysteria2 — userpass auth (не единый пароль)
- olcRTC — claims-based auth (user/pass из JSON-файла)
- Caddy — прокси для панели и NaiveProxy

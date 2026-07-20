# Конфигурация и деплой

## Сервер

| Параметр | Значение |
|----------|----------|
| IP | 31.76.8.29 |
| Хост | MyServer-1.play2go.cloud |
| Домен | 76t05pyu.ikill.baby |
| Порты | 80 (Caddy), 443 (Xray), 8443 (Caddy panel), 30000 (Hy2), 39743 (AWG), 444-448 (Mieru), 30001 (olcRTC WS) |

## Переменные окружения

См. `.env` файл в корне проекта.

## Скрипты

| Скрипт | Назначение |
|--------|-----------|
| `server/proxy_manager.sh` | Главный скрипт управления (v0.8) |
| `server/tmp_deploy_olcrtc.sh` | Деплой olcRTC бинарника |
| `server/tmp_add_user.sh` | Добавление Hy2 пользователя |
| `server/tmp_vless_mgr.sh` | Управление VLESS пользователями |
| `server/tmp_xray_fix.py` | Включение debug-логов Xray |
| `server/tmp_olcrtc_patch*.py` | Патчи olcRTC для claims auth |

## Внешние сервисы

| Сервис | Назначение | Конфигурация |
|--------|-----------|-------------|
| Jitsi Meet | olcRTC медиа-релей | URL: `https://meet.egovm.ru/pxy-76t05pyu.ikill.baby` |
| Caddy | Reverse proxy + NaiveProxy + Panel | Порт 80 (HTTP), 8443 (HTTPS panel) |

## Xray конфигурация (production)

Файл: `config/tmp_xray_v4.json`
- Протокол: VLESS + XHTTP + REALITY + Sniffing
- Порт: 443
- SNI: www.microsoft.com
- Исполнение: XHTTP (multiplexed HTTP transport)

Варианты в `config/`:
| Файл | Транспорт | Особенности |
|------|-----------|-------------|
| `tmp_xray_v2.json` | TCP+REALITY | Базовый |
| `tmp_xray_v3.json` | TCP+REALITY+Sniffing | С инспекцией трафика |
| `tmp_xray_v4.json` | **XHTTP+REALITY+Sniffing** | **Production** |
| `tmp_xray_xhttp.json` | XHTTP | Вариант XHTTP |
| `tmp_xray_grpc.json` | gRPC+REALITY | gRPC транспорт |
| `tmp_xray_cf.json` | TCP+REALITY | Cloudflare оптимизация |

## Пользователи

| Пользователь | Протоколы |
|-------------|-----------|
| Merlin | Все (hy2, awg, vless, naive, mieru, olcrtc) |
| Katya | awg, olcrtc |
| test | awg, olcrtc, vless |
| vless | vless |

## Лимиты

| Параметр | Значение | Примечание |
|----------|----------|-----------|
| Xray порт | 443 | Стандартный HTTPS порт |
| Hy2 порт | 30000 UDP | Только UDP |
| AWG порт | 39743 UDP | WireGuard-based |
| Mieru порты | 444-448 | 5 портов |
| olcRTC порт | 30001 WS | WebSocket |
| Caddy панель | 8443 | HTTPS + basicauth |

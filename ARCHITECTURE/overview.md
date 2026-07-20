# Обзор проекта NYX Panel

## Описание

**NYX Panel** — мультипротокольная система управления прокси/VPN сервером. Управляет 6 протоколами через Bash-скрипты, Flask-панель и включает клиентские приложения (olcbox KMP, olcRTC).

## Стек технологий

- **Сервер:** Ubuntu 22.04+, Xray (VLESS+XHTTP+REALITY), Hysteria2, AmneziaWG, Caddy (NaiveProxy + reverse proxy), Mieru, olcRTC
- **Панель:** Flask + SQLite + Caddy (basicauth reverse proxy)
- **Клиенты:** Kotlin Multiplatform (olcbox), Go (olcRTC tunnel)
- **Скрипты:** Bash + Python (jq, yq, qrencode, awg)
- **Языки:** Bash, Python, Go, Kotlin, Java (JNI C)

## Репозитории GitHub

| Проект | URL |
|--------|-----|
| NYX Panel | `https://github.com/smartor777-sketch/nyxpanel` |
| olcRTC (модифицированный) | `https://github.com/smartor777-sketch/olcrtc-users` |
| olcbox (KMP клиент) | `https://github.com/smartor777-sketch/olcbox-me` |

## Навигация

| Файл | Содержимое |
|------|-----------|
| [`components.md`](components.md) | Ключевые компоненты: сервер, протоколы, панель, olcbox, olcRTC |
| [`flows.md`](flows.md) | Потоки данных: подключение, аутентификация, управление |
| [`config.md`](config.md) | Конфигурация, env vars, скрипты, внешние сервисы, лимиты |
| [`protocols.md`](protocols.md) | Детали протоколов: VLESS, Hy2, AWG, Mieru, NaiveProxy, olcRTC |

# Установка NYX Panel на новый сервер

## Требования

- Чистый **Debian 12/13** (bookworm/trixie), **x86_64**
- **root** доступ
- Домен, A-запись которого указывает на IP сервера
- Открытые порты: 80, 443, 8443, 4433, 30000, 444-448, 39743

## Быстрая установка

```bash
# Скачать скрипт
curl -sL https://raw.githubusercontent.com/smartor777-sketch/nyxpanel/master/server/install.sh -o install.sh

# Запустить (домен обязателен)
DOMAIN="panel.kuban-forum.ru" bash install.sh
```

Скрипт спросит домен, если не передан через `DOMAIN=`. Остальные параметры можно переопределить переменными:

```bash
DOMAIN="panel.kuban-forum.ru" \
PANEL_PASS="mypassword" \
EMAIL="admin@example.com" \
bash install.sh
```

## Что устанавливается

| Компонент | Порт | Назначение |
|-----------|------|------------|
| Caddy + forwardproxy | 443 | Панель + HTTPS CONNECT proxy + fallback-сайт |
| sing-box (NaiveProxy) | 8443 | NaiveProxy inbound |
| Xray (VLESS+REALITY) | 4433 | VLESS трафик |
| Hysteria 2 | 30000 UDP | Hy2 трафик |
| Mieru (mita) | 444-448 | Mieru трафик |
| AmneziaWG | 39743 UDP | WireGuard-based VPN |
| olcRTC | 39743 | WebRTC tunnel |
| Flask panel | 5000 (local) | Веб-панель управления |

## Структура после установки

```
:443 ─ Caddy ─┬─ /panel* /user* /self* → Flask :5000
              ├─ CONNECT (forward_proxy) → HTTPS tunnel
              └─ всё остальное → file_server (заглушка "НКТ-Консалтинг")

:8443 ─ sing-box ─ NaiveProxy inbound
:4433 ─ xray ─ VLESS+REALITY
:30000 ─ hysteria2 ─ Hy2
:444-448 ─ mita ─ Mieru
:39743 ─ olcrtc + awg
```

## Управление

```bash
# Интерактивное меню
bash /root/proxy_manager.sh

# Добавить пользователя с протоколом
bash /root/proxy_manager.sh add_user <username> hy2
bash /root/proxy_manager.sh add_user <username> vless
bash /root/proxy_manager.sh add_user <username> naive
# и т.д.

# Удалить пользователя
bash /root/proxy_manager.sh del_user <username>

# Список пользователей
bash /root/proxy_manager.sh list_users
```

Панель: `https://{DOMAIN}/self/login` (admin / пароль из вывода install.sh)

## Что делает install.sh по шагам

1. **Базовая настройка**: apt, swap, UFW
2. **Xray**: установка + генерация REALITY ключей
3. **sing-box (NaiveProxy)**: установка + конфиг на :8443
4. **Caddy**: компиляция с xcaddy + forwardproxy, Caddyfile с панелью + forward_proxy + fallback
5. **Hysteria 2**: установка + self-signed сертификат
6. **Mieru**: установка mita
7. **olcRTC**: установка бинарника
8. **AmneziaWG**: установка + настройка
9. **Панель**: Flask + proxy_manager.sh
10. **Watchdog**: cron каждые 5 минут
11. **Let's Encrypt**: сертификаты (для Caddy, sing-box, Hy2)

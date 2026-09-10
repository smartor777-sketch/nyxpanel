# Telegram WEB Proxy (tproxy-server)

## Обзор

Сервер WEB-прокси для Telegram на основе [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server). Позволяет Telegram клиентам (Desktop, Android, iOS) проксировать MTProto-соединения через WebView/HTTPS.

## Архитектура

```
Internet :80/:443 → Caddy
                      ├── panel.example.com → Flask :5000 (NYX панель)
                      └── bot.example.com → tproxy-server :8090 (relay)
                                              └── mtproxy :2398 (official backend)
```

## Требования

- Сервер: x86_64 Linux (Debian 12+)
- Go 1.20+ (уже установлен на prod)
- Порты 80/443 открыты
- DNS: A-запись `bot.example.com → 203.0.113.10`

## Установка

### 1. DNS

Добавить A-запись для `bot.example.com`.

### 2. Загрузка файлов на сервер

```powershell
# Из Windows (PowerShell)
cd C:\Users\Alex\nyxpanel
$hostname = "203.0.113.10"
$password = "<пароль_старого_prod>"

# Загрузить все файлы tproxy
Get-ChildItem server\tproxy\* | ForEach-Object {
    & pscp -P 22 -pw $password $_.FullName "root@${hostname}:/tmp/tproxy/$($_.Name)"
}

# Или через SCP
scp -r server/tproxy/* root@${hostname}:/tmp/tproxy/
```

### 3. Запуск установщика

```bash
ssh root@203.0.113.10
cd /tmp/tproxy
chmod +x deploy-tproxy.sh
./deploy-tproxy.sh
```

Скрипт автоматически:
- Собирает tproxy-server из исходников
- Собирает official MTProxy
- Создаёт системных пользователей (tproxy, mtproxy)
- Устанавливает конфигурацию
- Создаёт systemd-сервисы
- Обновляет Caddyfile (добавляет блок bot.example.com)
- Запускает все сервисы

### 4. Проверка

```bash
# Статус сервисов
systemctl --no-pager --full status caddy mtproxy tproxy-server

# Relay готов
curl --fail http://127.0.0.1:8081/readyz

# Сайт доступен
curl --fail https://bot.example.com/

# Логи
journalctl -u tproxy-server -u mtproxy --since '30 minutes ago'
```

## Клиентская настройка

Пользователь вводит в Telegram:
- **Hostname:** `bot.example.com`
- **Secret:** (выводится при установке)

Или по ссылке:
```
https://t.me/webproxy?server=bot.example.com&secret=<SECRET>
```

## Порты (безопасность)

| Порт | Сервис | Внешний доступ |
|------|--------|----------------|
| 80 | Caddy | ✅ (ACME + redirect) |
| 443 | Caddy | ✅ (panel + tg) |
| 2398 | mtproxy | ❌ (nftables drop) |
| 8090 | tproxy-server | ❌ (loopback) |
| 8081 | tproxy-server admin | ❌ (loopback) |
| 8888 | mtproxy stats | ❌ (nftables drop) |

## Управление профилями

Профили хранятся в `/etc/tproxy-server/profiles.json`:

```json
{
  "profiles": [
    {
      "name": "default",
      "secret": "00112233445566778899aabbccddeeff",
      "backend": "127.0.0.1:2398",
      "carrier_mode": "https"
    }
  ]
}
```

Для добавления профиля:
1. Сгенерировать secret: `openssl rand -hex 16`
2. Добавить запись в profiles.json
3. Перезапустить: `systemctl restart tproxy-server`

## Обновление MTProxy конфига

Конфиг обновляется автоматически раз в сутки через `refresh-mtproxy-config.timer`.

Ручное обновление:
```bash
curl -s https://core.telegram.org/getProxySecret -o /etc/mtproxy/proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o /etc/mtproxy/proxy-multi.conf
systemctl restart mtproxy
```

## Структура файлов

```
server/tproxy/
├── config.json              # Конфигурация tproxy-server
├── profiles.json.example    # Пример profiles.json
├── firewall.nft             # nftables правила
├── mtproxy.env              # Переменные для MTProxy
├── tproxy-server.service    # Systemd: Go relay
├── mtproxy.service          # Systemd: Official MTProxy
├── tproxy-firewall.service  # Systemd: nftables
├── caddyfile-tg-block       # Блок Caddy для bot.example.com
├── index.html               # Fallback сайт
└── deploy-tproxy.sh         # Скрипт установки
```

## Диагностика

```bash
# Relay health
curl http://127.0.0.1:8081/healthz
curl http://127.0.0.1:8081/readyz
curl http://127.0.0.1:8081/metrics

# MTProxy
journalctl -u mtproxy --since -5min | grep -c 'Disconnected from RPC Middle-End'

# Firewall
nft list table inet tproxy_backend

# Порты (внешние не должны отвечать)
nc -vz -w 3 203.0.113.10 2398
nc -vz -w 3 203.0.113.10 8888
```

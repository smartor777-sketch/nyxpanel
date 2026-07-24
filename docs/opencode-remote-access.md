# OpenCode Remote Access Guide

Удалённый доступ к OpenCode серверу на Debian.

## Содержание

1. [Установка OpenCode на сервере](#установка)
2. [Системный сервис для работы 24/7](#системный-сервис)
3. [Способ 1: SSH туннель](#ssh-туннель)
4. [Способ 2: Веб-интерфейс](#веб-интерфейс)
5. [Способ 3: Tailscale](#tailscale)
6. [Безопасность](#безопасность)

---

## Установка

```bash
curl -fsSL https://opencode.ai/install | bash
```

---

## Системный сервис

Для работы 24/7 без завершения при закрытии терминала.

### 1. Создание пользователя (если нет)

```bash
sudo useradd -m -s /bin/bash opencode
sudo passwd opencode
```

### 2. Включение linger (критично!)

Linger позволяет systemd запускать пользовательские сервисы даже без активной SSH-сессии.

```bash
# Разрешить пользователю запускать фоновые сервисы
sudo loginctl enable-linger opencode

# Проверить что linger включен
loginctl show-user opencode | grep Linger
# Должно быть: Linger=yes
```

### 3. Создание директории для конфигов

```bash
sudo -u opencode mkdir -p /home/opencode/.config/systemd/user
sudo -u opencode mkdir -p /home/opencode/.local/share/opencode
```

### 4. Создание systemd сервиса

```bash
sudo -u opencode tee /home/opencode/.config/systemd/user/opencode.service << 'EOF'
[Unit]
Description=OpenCode Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/opencode
Environment=HOME=/home/opencode
Environment=PATH=/home/opencode/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/opencode/.local/bin/opencode serve --hostname 0.0.0.0 --port 4096
Restart=always
RestartSec=10

# Безопасность
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/opencode/.local/share/opencode
ReadWritePaths=/home/opencode/.config/opencode

[Install]
WantedBy=default.target
EOF
```

### 5. Настройка переменных окружения

```bash
# Создать файл окружения для сервиса
sudo -u opencode tee /home/opencode/.config/systemd/user/opencode.env << 'EOF'
# API ключи LLM провайдеров
OPENAI_API_KEY=sk-xxx
ANTHROPIC_API_KEY=sk-ant-xxx

# Пароль для доступа к OpenCode серверу (обязательно!)
OPENCODE_SERVER_PASSWORD=your-strong-password-here
OPENCODE_SERVER_USERNAME=opencode

# Опционально: кастомная модель по умолчанию
# OPENCODE_DEFAULT_MODEL=anthropic/claude-sonnet-4-20250514
EOF
```

### 6. Запуск сервиса

```bash
# Перезагрузить конфиги systemd
sudo -u opencode systemctl --user daemon-reload

# Включить автозапуск
sudo -u opencode systemctl --user enable opencode.service

# Запустить сервис
sudo -u opencode systemctl --user start opencode.service

# Проверить статус
sudo -u opencode systemctl --user status opencode.service

# Посмотреть логи
sudo -u opencode journalctl --user -u opencode.service -f
```

### 7. Полезные команды

```bash
# Остановить сервис
sudo -u opencode systemctl --user stop opencode.service

# Перезапустить
sudo -u opencode systemctl --user restart opencode.service

# Отключить автозапуск
sudo -u opencode systemctl --user disable opencode.service

# Проверить что linger работает
loginctl show-user opencode | grep Linger

# Проверить что процесс работает
ps aux | grep "opencode serve"
```

---

## SSH Туннель

Самый простой и безопасный способ. Не требует открытия портов в firewall.

### С десктопа (Linux/macOS/Windows)

```bash
# Локальный проброс: localhost:4096 → сервер:4096
ssh -L 4096:localhost:4096 opencode@31.76.8.29

# Или в фоне (не закрывается при закрытии терминала)
ssh -f -N -L 4096:localhost:4096 opencode@31.76.8.29

# Или через tmux/screen на сервере (рекомендуется)
ssh opencode@31.76.8.29
tmux new -s opencode
opencode serve --hostname 0.0.0.0 --port 4096
# Отсоединиться: Ctrl+B, D
```

### Подключение клиента

```bash
# TUI на десктопе подключается к локальному порту
opencode attach http://localhost:4096

# Или через desktop приложение
# Указать адрес: http://localhost:4096
```

### Автоматизация (SSH config)

```bash
# ~/.ssh/config
Host opencode-server
    HostName 31.76.8.29
    User opencode
    Port 22
    LocalForward 4096 localhost:4096
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

### Подключение

```bash
ssh opencode-server
# Теперь OpenCode доступен на http://localhost:4096
```

---

## Веб-интерфейс

Доступ через браузер. Требует открытия порта в firewall.

### Запуск с веб-интерфейсом

```bash
# Вместо serve используем web (откроет браузер)
opencode web --hostname 0.0.0.0 --port 4096

# Или через systemd сервис (изменить ExecStart)
ExecStart=/home/opencode/.local/bin/opencode web --hostname 0.0.0.0 --port 4096
```

### Firewall

```bash
# UFW
sudo ufw allow 4096/tcp

# Или iptables
sudo iptables -A INPUT -p tcp --dport 4096 -j ACCEPT
```

### Доступ

Открыть в браузере:
```
http://31.76.8.29:4096
```

При запросе логина/пароля:
- Имя пользователя: `opencode` (или что задано в `OPENCODE_SERVER_USERNAME`)
- Пароль: значение `OPENCODE_SERVER_PASSWORD`

### Через reverse proxy (рекомендуется для продакшена)

```nginx
# /etc/nginx/sites-available/opencode
server {
    listen 443 ssl http2;
    server_name opencode.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/opencode.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/opencode.yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:4096;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/opencode /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

---

## Tailscale

Mesh-VPN. Zero-config, работает через NAT. Самый простой способ для удалённого доступа.

### Установка на сервере

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

После выполнения будет ссылка для авторизации в браузере.

### Установка на десктопе

```bash
# Linux
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# macOS
brew install tailscale
# Или скачать из App Store

# Windows
# Скачать с https://tailscale.com/download
```

### Настройка OpenCode для Tailscale

```bash
# Запустить OpenCode, слушать на всех интерфейсах
opencode serve --hostname 0.0.0.0 --port 4096
```

### Подключение

1. Узнать Tailscale IP сервера:
```bash
# На сервере
tailscale ip -4
# Например: 100.64.0.1
```

2. Подключиться с десктопа:
```bash
opencode attach http://100.64.0.1:4096

# Или через desktop приложение
# Адрес: http://100.64.0.1:4096
```

### Access Controls (опционально)

```json
// /etc/tailscale/acl.hujson
{
  "acls": [
    {
      // Разрешить доступ к OpenCode порту
      "action": "accept",
      "src": ["group:trusted"],
      "dst": ["autogroup:self:4096"]
    }
  ],
  "groups": {
    "group:trusted": ["user1@github.com", "user2@github.com"]
  }
}
```

### Преимущества Tailscale

| Преимущество | Описание |
|---|---|
| Zero-config | Не нужно настраивать firewall, NAT, port forwarding |
| Шифрование | Весь трафик шифруется через WireGuard |
| Mesh | Десктопы могут видеть друг друга напрямую |
| ACL | Гранularный контроль доступа |
| Stable IP | Tailscale IP не меняется |

---

## Безопасность

### Обязательные меры

1. **Пароль сервера** - всегда задавать `OPENCODE_SERVER_PASSWORD`
2. **Limiter** - ограничить доступ по IP в firewall
3. **Не использовать 0.0.0.0 в публичных сетях** - только через VPN/SSH

### Рекомендации

| Метод | Безопасность | Сложность | Скорость |
|---|---|---|---|
| SSH туннель | Максимальная | Простая | Зависит от SSH |
| Tailscale | Высокая | Простая | Быстрая |
| Веб-интерфейс (прямой) | Средняя | Простая | Быстрая |
| Веб-интерфейс (nginx+TLS) | Высокая | Средняя | Быстрая |

### Firewall правила

```bash
# Только SSH
sudo ufw allow 22/tcp

# SSH + OpenCode (если нужен прямой доступ)
sudo ufw allow 22/tcp
sudo ufw allow 4096/tcp

# Или только через Tailscale (рекомендуется)
sudo ufw default deny incoming
sudo ufw allow ssh
# Tailscale работает через UDP 41641, UFW разрешает по умолчанию
```

---

## Диагностика

### Проверка что сервис работает

```bash
# Статус сервиса
sudo -u opencode systemctl --user status opencode.service

# Логи
sudo -u opencode journalctl --user -u opencode.service -n 50

# Проверка порта
ss -tlnp | grep 4096

# Или
netstat -tlnp | grep 4096
```

### Проверка доступности

```bash
# С сервера
curl http://localhost:4096/global/health

# С десктопа (через SSH туннель)
curl http://localhost:4096/global/health

# С десктопа (через Tailscale)
curl http://100.64.0.1:4096/global/health
```

### Тест подключения

```bash
# Через CLI
opencode attach http://localhost:4096

# Проверка здоровья сервера
curl -u opencode:your-password http://localhost:4096/global/health
```

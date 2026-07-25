# Конфигурация и деплой

## Серверы

### Production

| Параметр | Значение |
|----------|----------|
| IP | 31.76.8.29 |
| Хост | MyServer-1.play2go.cloud |
| Домен | panel.kuban-forum.ru |
| Панель | `https://panel.kuban-forum.ru/self/login` |

### Dev (стенд)

| Параметр | Значение |
|----------|----------|
| IP | 2.26.51.8 |
| Хост | MyServer-stend.play2go.cloud |
| Домен | nyx.kuban-forum.ru |
| Панель | `https://nyx.kuban-forum.ru/self/login` |

## Порты

| Сервис | Порт | Протокол | Назначение |
|--------|------|----------|------------|
| Caddy | 443 | TCP+TLS | Панель + forward_proxy + fallback-сайт |
| sing-box (NaiveProxy) | 8443 | TCP+TLS | NaiveProxy inbound |
| xray (VLESS+Reality) | 4433 | TCP | Прокси-трафик клиентов |
| Caddy (http→https) | 80 | TCP | Редирект на HTTPS |
| Hysteria2 | 30000 | UDP | Hy2 трафик |
| Mieru | 444-448 | TCP+UDP | Mieru трафик |
| olcRTC | 39743 | UDP | WebRTC трафик |
| AWG | 39743 | UDP | WireGuard tunnel |
| panel (Flask) | 5000 | TCP (localhost) | Внутренний API |
| xray API | 10085 | TCP (localhost) | gRPC stats |

## Скрипты

| Скрипт | Назначение |
|--------|-----------|
| `server/install.sh` | Auto-install полного стека на чистый Debian |
| `server/proxy_manager.sh` | Главный скрипт управления (v0.9) |

## Установка сервисов (binary vs сборка)

| Сервис | Источник | Компиляция? |
|--------|----------|-------------|
| Caddy | xcaddy + `github.com/caddyserver/forwardproxy` | **Да** |
| sing-box | GitHub Releases (SagerNet/sing-box) | Нет |
| xray | GitHub Releases (XTLS/Xray-core) | Нет |
| Hysteria2 | GitHub Releases (apernet/hysteria) | Нет |
| Mieru (mita) | GitHub Releases (.deb) | Нет |
| olcRTC | GitHub Releases | Нет |
| AWG | apt (amneziawg) | Нет (DKMS) |

## Caddyfile (dev/prod)

```caddy
domain.com:443 {
    tls email@example.com

    route {
        handle /panel* { reverse_proxy 127.0.0.1:5000 }
        handle /user*  { reverse_proxy 127.0.0.1:5000 }
        handle /self*  { reverse_proxy 127.0.0.1:5000 }
        handle /samples/* { root * /opt/proxy-panel; file_server }
        handle /static/*  { root * /opt/proxy-panel; file_server }

        forward_proxy {
            basic_auth admin <password>
            hide_ip
            hide_via
            probe_resistance
        }

        root * /var/www/html
        file_server
    }
}
```

## Внешние сервисы

| Сервис | Назначение | Конфигурация |
|--------|-----------|-------------|
| Let's Encrypt | TLS сертификаты для Caddy + sing-box + Hy2 | `certbot` + авто-продление |
| Jitsi Meet | olcRTC медиа-релей | `meet.egovm.ru/nyx-{domain}` |

## Пользователи

| Пользователь | Протоколы |
|-------------|-----------|
| Alexander | Все |
| Katya | hy2, awg, naive, vless |
| Merlin | Все |
| Silky | Все |
| test | Все |

## Лимиты

| Параметр | Значение | Примечание |
|----------|----------|-----------|
| Xray порт | 4433 | Стандартный HTTPS порт |
| Hy2 порт | 30000 UDP | Только UDP |
| AWG порт | 39743 UDP | WireGuard-based |
| Mieru порты | 444-448 | 5 портов |
| Caddy порт | 443 | HTTPS |
| sing-box порт | 8443 | NaiveProxy |
| Panel (Flask) | 5000 | localhost only |
| OlcRTC порт | 39743 | WebRTC |

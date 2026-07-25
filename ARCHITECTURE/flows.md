# Потоки данных

## Подключение пользователя (клиент → прокси)

```
Клиент
   │
   ├── VLESS+REALITY → Xray :4433
   │
   ├── Hysteria 2 → hysteria2 :30000 UDP
   │
   ├── AmneziaWG → awg :39743 UDP
   │
   ├── NaiveProxy → sing-box :8443
   │
   ├── HTTPS CONNECT proxy → Caddy :443 (forward_proxy)
   │     └── basic_auth + probe_resistance
   │
   ├── Mieru → mita :444-448
   │
   └── olcRTC → olcrtc :39743
         └── WebRTC → Jitsi Meet
```

## Управление пользователем (админ → панель)

```
Администратор
   │
   ├── SSH → bash proxy_manager.sh
   │     ├── add_user
   │     ├── del_user
   │     └── status
   │
   └── Browser → https://panel.kuban-forum.ru/self/login
         └── Flask → Caddy reverse proxy → SQLite
```

## Сбор трафика (collector)

```
Cron (*/5 * * * *)
   │
   ├── Xray StatsService (gRPC :10085) → statsquery -reset
   ├── Hy2 trafficStats API (:30100)
   ├── AWG show + pubkey map
   │
   ├── SQLite (traffic_log per user)
   │
   └── Flask → Chart.js dashboard
```

## Traffic flow (будущее, модульная архитектура)

```
Прокси-сервер
   │
   ▼
Cron collector (python)
   │
   ├── Xray API → user stats
   ├── Hy2 API → user stats
   │
   ▼
SQLite
   │
   ▼
Flask → Chart.js → Dashboard
```

## Аутентификация olcRTC

```
olcRTC Client → Server
   │              │
   ▼              ▼
claims: user+pass → createFileAuthHook() → JSON users file
   │
   ├── Найден? → проверяет pass
   │   ├── Совпадает? → OK
   │   └── Не совпадает? → PASSWORD_MISMATCH
   └── Не найден? → USER_NOT_FOUND
   │
   ▼
Session → WebRTC → Jitsi
```

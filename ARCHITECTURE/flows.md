# Потоки данных

## Подключение пользователя (клиент → прокси)

```
Клиент (olcbox/olcRTC/Xray/Hysteria2)
       │
       ▼
  Прокси-сервер
       │
       ├── VLESS+XHTTP+REALITY (443)
       │     └── Xray → REALITY → XHTTP → VLESS
       │
       ├── Hysteria 2 (30000 UDP)
       │     └── hysteria-server → userpass auth
       │
       ├── AmneziaWG (39743 UDP)
       │     └── awg → WireGuard крипто
       │
       ├── NaiveProxy (80)
       │     └── Caddy → forwardproxy
       │
       ├── Mieru (444-448)
       │     └── mieru → AES-GCM туннель
       │
       └── olcRTC (30001 WS)
             └── olcrtc → WebRTC → Jitsi Meet
                   └── claims auth (user/pass)
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
       └── Browser → https://76t05pyu.ikill.baby:8443/panel/
             └── Flask → Caddy basicauth → SQLite
```

## Аутентификация olcRTC

```
olcRTC Client
       │
       ▼
  ws://76t05pyu.ikill.baby:30001
       │
       ▼
  Server (server.go)
       │
       ├── claims: user + pass
       │
       ▼
  createFileAuthHook()
       │
       ├── Читает tmp_users.json
       ├── Ищет user в JSON
       │   ├── Найден? → проверяет pass
       │   │   ├── Совпадает? → OK
       │   │   └── Не совпадает? → PASSWORD_MISMATCH
       │   └── Не найден? → USER_NOT_FOUND
       │
       ▼
  Session → WebRTC подключение → Jitsi
       │
       ├── Обмен ключами (XChaCha20-Poly1305)
       ├── smux мультиплексирование
       └── TCP over DataChannel
```

## Traffic flow (будущее, Stage 1 панели)

```
Прокси-сервер
       │
       ▼
  Cron collector (python/bash)
       │
       ├── iptables/nftables → traffic bytes
       ├── Xray API → user stats
       ├── Hy2 API → user stats
       │
       ▼
  SQLite (на сервере или на панели)
       │
       ▼
  Flask → Chart.js → Dashboard
```

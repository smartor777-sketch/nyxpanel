<div align="center">

[**RU**](README.ru.md) / **EN**

</div>

# NYX Panel

Multi-protocol proxy management panel with web interface.

## Features

- **Multi-protocol support**: VLESS (XHTTP+REALITY), Hysteria 2, Trojan, AmneziaWG, Mieru, NaiveProxy, olcRTC
- **User dashboard**: traffic charts, QR codes, subscription URLs
- **Admin panel**: user management, protocol control, traffic monitoring
- **Mobile app**: [OlcboxME](https://github.com/smartor777-sketch/nyxpanel) Android client with built-in olcRTC support
- **Cross-platform clients**: Android, Windows, Linux

## Supported Protocols

| Protocol | Type | Client |
|----------|------|--------|
| VLESS+XHTTP+REALITY | Proxy | Happ, Hiddify, v2RayTun, Exclave |
| Hysteria 2 | Proxy | Happ, Hiddify, v2RayTun, Exclave |
| Trojan | Proxy | Happ, Hiddify, v2RayTun, Exclave, NekoBox |
| AmneziaWG | VPN | Amnezia VPN (≥5.0), NekoBox |
| Mieru | Proxy | NekoBox |
| NaiveProxy | Proxy | Happ, Hiddify, v2RayTun, Exclave |
| olcRTC | Proxy | OlcboxME (mobile only), uses [olcrtc-users](https://github.com/smartor777-sketch/olcrtc-users) fork |
| **Telegram MTProxy** | Proxy | Official Telegram clients |

## Telegram MTProxy

Each user gets their own MTProxy profile with a unique secret. Two modes available:

### Isolated Mode
- Dedicated `mtproto-proxy` process per user
- Runs on unique port (2401-2499)
- Full resource allocation (~20-35 MB RAM per instance)

### Shared Mode
- Multiple users share a single `mtproto-proxy` instance
- Runs on shared ports (2501-2504)
- Saves RAM — only ~20 MB for the shared instance regardless of user count
- Each user keeps their own unique secret
- Shared instance accepts multiple secrets via pool file (`-S` flags)

### Switching Modes
- Toggle between isolated ↔ shared from the panel UI
- **Secret never changes** — users don't need to update their client
- Brief shared MTProxy restart (~1s) when pool changes

### Transport Modes

| Mode | HTTP Port | TCP Port |
|------|-----------|----------|
| HTTPS | 2501 | 3501 |
| HTTPS Lanes | 2502 | 3502 |
| WebSocket | 2503 | 3503 |
| WebSocket Lanes | 2504 | 3504 |

### Key Files
```
/etc/tproxy-server/
├── profiles.json         # MTProxy profiles (unique secrets)
├── modes.json            # shared/isolated per profile
└── tg_mappings.json      # Telegram user mappings

/etc/mtproxy/
├── mtproxy-shared-*.secrets   # Secret pools for shared instances
└── mtproxy-<name>.env         # Isolated instance configs
```

## Password Management

### Password Storage
Passwords are **hashed** (not encrypted) using `werkzeug.security.generate_password_hash()` with PBKDF2-SHA256. This is a one-way function - passwords cannot be recovered from the database.

### Admin Password Reset
If a user forgets their password, the **admin can set a new one** through the admin panel:
1. Open Admin Panel - Users table - Password column
2. Click "Set" button - Enter new password - Confirm
3. The user can then log in with the new password

### User Self-Service Password Change
Users can change their own password from their dashboard:
1. Click "Change password" button in the header
2. Enter current password - Enter new password - Click "Save"
3. Requires current password for security verification

**Workflow for password recovery:**
> If user forgets password - Admin resets it - User logs in - User changes to their own password

## Architecture

- **Panel**: Flask + SQLite + Caddy reverse proxy
- **Protocols**: Xray (VLESS), sing-box (Hysteria2, Trojan), WireGuard (AmneziaWG), Mieru, NaiveProxy, olcRTC
- **Clients**: OlcboxME (Kotlin Multiplatform), olcRTC (Go WebRTC tunnel)
- **Traffic collector**: Python cron job collecting stats from protocol APIs

## Disk Usage & Cleanup

The installer builds `xcaddy` (Caddy + NaiveProxy plugin) from source using Go. After installation, Go and build caches remain on disk and can be safely removed to free space:

| Path | Size | Description | Safe to delete? |
|------|------|-------------|-----------------|
| `/usr/local/go` | ~250 MB | Go SDK (used only during install) | Yes, after install |
| `/root/go` | ~2.5 GB | Go build cache & modules | Yes, after install |
| `/root/.cache` | ~2 GB | pip/go build cache | Yes |
| `/root/.gradle` | ~1.7 GB | Gradle cache (dev server only) | Yes (will rebuild) |
| `/opt/android-sdk` | ~2.8 GB | Android SDK (dev server only) | Only on dev |

**To clean build artifacts after install:**
```bash
rm -rf /usr/local/go /root/go /root/.cache
```

This frees ~5 GB. The `xcaddy` binary at `/usr/local/bin/xcaddy` is already compiled and does not depend on Go after installation.

## Links

- **Repository**: [github.com/smartor777-sketch/nyxpanel](https://github.com/smartor777-sketch/nyxpanel)
- **olcRTC fork**: [github.com/smartor777-sketch/olcrtc-users](https://github.com/smartor777-sketch/olcrtc-users)
- **Original olcRTC**: [github.com/openlibrecommunity/olcrtc](https://github.com/openlibrecommunity/olcrtc)

## License

Proprietary. All rights reserved.

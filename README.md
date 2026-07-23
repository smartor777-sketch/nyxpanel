# NYX Panel

Multi-protocol proxy management panel with web interface.

## Features

- **Multi-protocol support**: VLESS (XHTTP+REALITY), Hysteria 2, AmneziaWG, Mieru, NaiveProxy, oRTC
- **User dashboard**: traffic charts, QR codes, subscription URLs
- **Admin panel**: user management, protocol control, traffic monitoring
- **Mobile app**: OlcboxME Android client with built-in oRTC support

## Password Management

### Password Storage
Passwords are **hashed** (not encrypted) using `werkzeug.security.generate_password_hash()` with PBKDF2-SHA256. This is a one-way function — passwords cannot be recovered from the database.

### Admin Password Reset
If a user forgets their password, the **admin can set a new one** through the admin panel:
1. Open Admin Panel → Users table → Password column
2. Click "Уст." (Set) button → Enter new password → Confirm
3. The user can then log in with the new password

### User Self-Service Password Change
Users can change their own password from their dashboard:
1. Click "🔐 Изм. пароль" (Change password) button in the header
2. Enter current password → Enter new password → Click "Сохранить" (Save)
3. Requires current password for security verification

**Workflow for password recovery:**
> If user forgets password → Admin resets it → User logs in → User changes to their own password

## Architecture

- **Panel**: Flask + SQLite + Caddy reverse proxy
- **Protocols**: Xray (VLESS), sing-box (Hysteria2), WireGuard (AmneziaWG), Mieru, NaiveProxy
- **Clients**: OlcboxME (Kotlin Multiplatform), oRTC (Go WebRTC tunnel)

## Servers

| Environment | IP | Domain | Port |
|-------------|-----|--------|------|
| Production | 31.76.8.29 | 76t05pyu.ikill.baby | 8443 |
| Development | 2.26.51.8 | nyx.kuban-forum.ru | 8443 |

## License

Proprietary. All rights reserved.

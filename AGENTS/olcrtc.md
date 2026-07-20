# olcRTC (Go Tunnel)

## Структура

`server/olcrtc-users/` — форк `github.com/openlibrecommunity/olcrtc`.

WebRTC-based encrypted TCP tunnel masquerading as video calls.

## Ключевые компоненты

| Компонент | Путь | Описание |
|-----------|------|----------|
| Entry point | `cmd/olcrtc/main.go` | CLI entry |
| Server | `internal/server/server.go` | Server logic |
| Session | `internal/app/session/session.go` | Session management |
| Auth | `internal/auth/auth.go` | Auth providers (jitsi, telemost, wbstream) |
| Claims auth | `internal/auth/auth.go` + `createFileAuthHook` | User/pass из JSON-файла |
| Transport | `internal/transport/` | DataChannel, VP8, SEI, Video |
| Crypto | `internal/crypto/chacha.go` | XChaCha20-Poly1305 |
| Engine | `internal/engine/` | WebRTC engine (goolom, jitsi, livekit) |
| Mobile | `mobile/mobile.go` | gomobile bindings |

## Сборка

```bash
cd server/olcrtc-users
mage build        # сборка
mage check        # линтер + тесты
mage lint         # golangci-lint
go test -race ./... # тесты с race detector
```

## Правила

- WTFPL лицензия
- Conventional commits (англ)
- Pure Go, минимум внешних зависимостей
- Go 1.26+
- AI-сгенерированный код помечать `// ai-generated` (кроме пользователя zaraza/zarazaex)
- Функции < 60 statements, cyclomatic complexity < 15
- Изменения в auth — проверить `config/tmp_users.json` совместимость

# olcbox (KMP Client)

## Структура

`android/olcbox/` — Kotlin Multiplatform проект (Android + iOS + Desktop).

| Модуль | Платформы |
|--------|-----------|
| `sharedUI/` | Common (Compose Multiplatform) |
| `androidApp/` | Android (VpnService, TUN, JNI) |
| `desktopApp/` | JVM Desktop (macOS/Windows/Linux) |
| `iosApp/` | iOS (SwiftUI + SwiftOlcRtcManager) |

## Ключевые компоненты

- `sharedUI/src/commonMain/kotlin/org/olcbox/app/vpn/VpnManager.kt` — VPN-интерфейс
- `sharedUI/src/commonMain/kotlin/org/olcbox/app/data/model/LocationConfig.kt` — конфиг локации
- `androidApp/src/main/kotlin/org/olcbox/app/OlcboxQsTileService.kt` — Quick Settings tile
- JNI: `androidApp/src/main/jni/olcbox_tun2socks_jni.c` + hev-socks5-tunnel

## Сборка

- Gradle (Kotlin DSL)
- Version catalog: `gradle/libs.versions.toml`
- Makefile для быстрых команд

## Правила

- Изменения в sharedUI = изменения на всех платформах
- JNI код только при необходимости (C-зависимости)
- При добавлении фичи — проверить commonMain, androidMain, iosMain, jvmMain

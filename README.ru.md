<div align="center">

**RU** / [EN](README.md)

</div>

# NYX Panel

Мультипротокольная панель управления прокси с веб-интерфейсом.

## Возможности

- **Поддержка протоколов**: VLESS (XHTTP+REALITY), Hysteria 2, Trojan, AmneziaWG, Mieru, NaiveProxy, olcRTC
- **Личный кабинет**: графики трафика, QR-коды, ссылки подписок
- **Админ-панель**: управление пользователями, контроль протоколов, мониторинг трафика
- **Мобильное приложение**: [OlcboxME](https://github.com/smartor777-sketch/nyxpanel) - Android-клиент с встроенной поддержкой olcRTC
- **Кроссплатформенные клиенты**: Android, Windows, Linux

## Поддерживаемые протоколы

| Протокол | Тип | Клиент |
|----------|-----|--------|
| VLESS+XHTTP+REALITY | Прокси | Happ, Hiddify, v2RayTun, Exclave |
| Hysteria 2 | Прокси | Happ, Hiddify, v2RayTun, Exclave |
| Trojan | Прокси | Happ, Hiddify, v2RayTun, Exclave, NekoBox |
| AmneziaWG | VPN | AmneziaWG клиент, NekoBox |
| Mieru | Прокси | NekoBox |
| NaiveProxy | Прокси | Happ, Hiddify, v2RayTun, Exclave |
| olcRTC | Прокси | OlcboxME (только мобильные) |

## Управление паролями

### Хранение паролей
Пароли **хэшируются** (не шифруются) с помощью `werkzeug.security.generate_password_hash()` и PBKDF2-SHA256. Это односторонняя функция - пароли невозможно восстановить из базы данных.

### Сброс пароля администратором
Если пользователь забыл пароль, **администратор может установить новый** через админ-панель:
1. Открыть Админ-панель - Таблица пользователей - Колонка пароля
2. Нажать кнопку "Уст." - Ввести новый пароль - Подтвердить
3. Пользователь сможет войти с новым паролем

### Смена пароля пользователем
Пользователи могут сменить пароль самостоятельно из личного кабинета:
1. Нажать кнопку "Изм. пароль" в шапке
2. Ввести текущий пароль - Ввести новый пароль - Нажать "Сохранить"
3. Требуется текущий пароль для проверки безопасности

**Процесс восстановления пароля:**
> Пользователь забыл пароль - Администратор сбрасывает - Пользователь входит - Пользователь меняет на свой пароль

## Архитектура

- **Панель**: Flask + SQLite + Caddy reverse proxy
- **Протоколы**: Xray (VLESS), sing-box (Hysteria2, Trojan), WireGuard (AmneziaWG), Mieru, NaiveProxy, olcRTC
- **Клиенты**: OlcboxME (Kotlin Multiplatform), olcRTC (Go WebRTC туннель)
- **Сборщик трафика**: Python cron-задача, собирающая статистику из API протоколов

## Использование диска и очистка

Инсталлятор собирает `xcaddy` (Caddy + NaiveProxy плагин) из исходников с помощью Go. После установки Go и кэш сборки остаются на диске и могут быть безопасно удалены:

| Путь | Размер | Описание | Безопасно удалять? |
|------|--------|----------|-------------------|
| `/usr/local/go` | ~250 MB | Go SDK (только при установке) | Да, после установки |
| `/root/go` | ~2.5 GB | Кэш сборки Go и модули | Да, после установки |
| `/root/.cache` | ~2 GB | Кэш pip/go | Да |
| `/root/.gradle` | ~1.7 GB | Кэш Gradle (только dev-сервер) | Да (пересоберётся) |
| `/opt/android-sdk` | ~2.8 GB | Android SDK (только dev-сервер) | Только на dev |

**Очистка после установки:**
```bash
rm -rf /usr/local/go /root/go /root/.cache
```

Освобождает ~5 GB. Бинарник `xcaddy` в `/usr/local/bin/xcaddy` уже скомпилирован и не зависит от Go после установки.

## Ссылки

- **Репозиторий**: [github.com/smartor777-sketch/nyxpanel](https://github.com/smartor777-sketch/nyxpanel)
- **Форк olcRTC**: [github.com/smartor777-sketch/olcrtc-users](https://github.com/smartor777-sketch/olcrtc-users)
- **Оригинальный olcRTC**: [github.com/openlibrecommunity/olcrtc](https://github.com/openlibrecommunity/olcrtc)

## Лицензия

Proprietary. All rights reserved.

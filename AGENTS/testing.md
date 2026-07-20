# Testing

## Быстрые команды

| Команда | Описание |
|---------|----------|
| `cd server/olcrtc-users && go test -race ./...` | Все тесты olcRTC |
| `cd server/olcrtc-users && mage check` | Линтер + тесты |
| `bash -n server/proxy_manager.sh` | Проверка синтаксиса Bash |
| `python -m py_compile server/tmp_*.py` | Проверка синтаксиса Python |
| `cd android/olcbox && ./gradlew test` | Тесты olcbox (KMP commonTest) |

## Правила

- Тестировать **поведение**, а не файлы
- Для Bash-скриптов — `bash -n` минимум
- Для Python — `python -m py_compile`
- Для Go — `go test -race ./...`
- Не тестировать: константы, простые обёртки

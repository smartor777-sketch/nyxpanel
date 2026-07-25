# AGENTS.md

## Инструкции для AI-агентов

При выполнении задач загружай только нужные файлы из папки `AGENTS/`:

| Файл | Когда загружать |
|------|----------------|
| [`AGENTS/rules.md`](AGENTS/rules.md) | Всегда (базовые правила) |
| [`AGENTS/proxy.md`](AGENTS/proxy.md) | Когда работаешь с протоколами (VLESS, Hy2, AWG, Mieru, NaiveProxy) |
| [`AGENTS/panel.md`](AGENTS/panel.md) | Когда работаешь с Flask-панелью |
| [`AGENTS/server.md`](AGENTS/server.md) | Когда работаешь с серверными скриптами и деплоем |
| [`AGENTS/android.md`](AGENTS/android.md) | Когда работаешь с olcbox (KMP Android/iOS/Desktop) |
| [`AGENTS/olcrtc.md`](AGENTS/olcrtc.md) | Когда работаешь с olcRTC (Go-туннель) |
| [`AGENTS/docs.md`](AGENTS/docs.md) | Когда работаешь с документацией |
| [`AGENTS/testing.md`](AGENTS/testing.md) | Когда пишешь или запускаешь тесты |
| [`AGENTS/codestyle.md`](AGENTS/codestyle.md) | Всегда — стиль кода, комментарии |

## Проекты

| Проект | Путь | Описание |
|--------|------|----------|
| **NYX Panel** | `C:\Users\Alex\nyxpanel\` | Текущий проект — multi-protocol proxy management panel |
| **Telegram бот** | `C:\Users\Alex\durable-object-starter\` | VikaBot Telegram bot |

## Skills (автоматически загружаются)

| Skill | Когда |
|-------|-------|
| `conventions-core` | ВСЕГДА при написании/редактировании кода |
| `rules` | ВСЕГДА (базовые правила) |

## Дополнительно

- Архитектура: [`ARCHITECTURE.md`](ARCHITECTURE.md)

### Prod
- Сервер: `31.76.8.29` (MyServer-1.play2go.cloud), домен `panel.kuban-forum.ru`
- Панель: `https://panel.kuban-forum.ru/self/login`
- Рабочий, через него идут соединения

### Dev (стенд)
- Сервер: `2.26.51.8`, хост `MyServer-stend.play2go.cloud`, домен `oootubww.ikill.baby`
- Установлен через pxy, все протоколы
- Разработка панели, olcbox, olcRTC бинарников
- Готовое переносится на prod

## graphify

This project has a graphify knowledge graph (if enabled).

### Порядок поиска информации

1. **Структура кода**: сначала `graphify query "..." --budget 1500`, если мало — Read файл
2. **Правила кода**: см. `AGENTS/rules.md` (всегда загружается)
3. **Архитектура**: `graphify query "..." --budget 1500`, если мало — Read
4. **Потоки данных**: `graphify query "..." --dfs --budget 1500`, subagent для трассировки
5. **Большое исследование (>3 файлов)**: dispatch subagent, получи краткий ответ

### Правила

- Прежде чем читать `ARCHITECTURE/*.md` — попробуй `graphify query "..." --budget 1500`
- Если графа не хватает — тогда файл целиком
- После правки кода запускай `graphify update .` (AST-only, без API-стоимости)

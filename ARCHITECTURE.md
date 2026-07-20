# ARCHITECTURE.md
# Архитектура проекта NYX Panel

> Полная документация по архитектуре разбита на функциональные файлы.

## Навигация

При работе с проектом загружай только нужный файл из папки `ARCHITECTURE/`:

| Файл | Когда загружать |
|------|----------------|
| [`ARCHITECTURE/overview.md`](ARCHITECTURE/overview.md) | Обзор проекта, стек технологий, структура директорий |
| [`ARCHITECTURE/components.md`](ARCHITECTURE/components.md) | Ключевые компоненты: сервер, протоколы, панель, olcbox, olcRTC |
| [`ARCHITECTURE/flows.md`](ARCHITECTURE/flows.md) | Потоки данных: подключение, аутентификация, управление |
| [`ARCHITECTURE/config.md`](ARCHITECTURE/config.md) | Конфигурация сервера, env vars, скрипты, внешние сервисы, лимиты |
| [`ARCHITECTURE/protocols.md`](ARCHITECTURE/protocols.md) | Детали протоколов: VLESS+XHTTP+REALITY, Hysteria2, AWG, Mieru, NaiveProxy, olcRTC |
| [`ARCHITECTURE/modules.md`](ARCHITECTURE/modules.md) | Модульная архитектура: Protocol Agent, Service Registry, Panel Core |

Паттерны и правила — в `AGENTS/rules.md` и `AGENTS/proxy.md`.

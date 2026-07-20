# Системные требования NYX Panel

> Дата: 2026-07-18
> Версия: 1.0

---

## 1. Целевая ОС

| Требование | Значение |
|-----------|----------|
| **ОС** | Linux (любой дистрибутив) |
| **Рекомендуется** | Debian 11+ / Ubuntu 22.04+ |
| **Поддерживается** | Любой дистрибутив с systemd и Python 3 |
| **Не поддерживается** | Windows (нет смысла для серверной панели), Alpine (нет systemd) |

**Почему Debian/Ubuntu:**
- Самый широкий охват у VPS-провайдеров
- systemd по умолчанию (все сервисы — systemd units)
- Стандартные пути конфигов (`/etc/`)
- APT для зависимостей
- Минимальный расход ресурсов

**Другие дистрибутивы** — будут работать, если есть systemd и Python 3. Отличия только в путях и пакетном менеджере.

---

## 2. Зависимости

### Panel Core (требуются всегда)

| Компонент | Версия | Установка |
|-----------|--------|-----------|
| Python 3 | >= 3.10 | `apt install python3` |
| pip | >= 21 | `apt install python3-pip` |
| Flask | latest | `pip install flask` |
| SQLite3 | built-in | встроен в Python |
| Caddy | >= 2.7 | `apt install caddy` (из официального репозитория) |

### Protocol Agent (зависит от набора протоколов)

**Общие:**
| Инструмент | Для чего | Установка |
|-----------|----------|-----------|
| `jq` | Работа с JSON конфигами | `apt install jq` |
| `curl` | HTTP запросы | `apt install curl` |

**Xray (VLESS+XHTTP+REALITY):**
| Компонент | Установка |
|-----------|----------|
| Xray-core | `bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)"` |
| `jq` | `apt install jq` |

**Hysteria 2:**
| Компонент | Установка |
|-----------|----------|
| hysteria-server | `bash <(curl -fsSL https://get.hy2.sh/)` |

**Caddy (NaiveProxy + reverse proxy):**
| Компонент | Установка |
|-----------|----------|
| Caddy | `apt install caddy` |
| forward_proxy модуль | требуется сборка с `xcaddy` |

**AmneziaWG:**
| Компонент | Установка |
|-----------|----------|
| amneziawg-tools | `apt install amneziawg` (из репозитория проекта) |
| `qrencode` | `apt install qrencode` |

**Mieru:**
| Компонент | Установка |
|-----------|----------|
| mita (сервер) | `bash <(curl -fsSL https://mieru.dev/install-mita.sh)` |

**olcRTC:**
| Компонент | Установка |
|-----------|----------|
| olcrtc binary | Сборка из Go или готовый бинарник |

---

## 3. Системные ресурсы

### Минимальные (панель + 1-2 протокола)

| Ресурс | Значение |
|--------|----------|
| **CPU** | 1 core (x86_64 / arm64) |
| **RAM** | 256 MB |
| **Диск** | 1 GB |

### Рекомендуемые (панель + все 6 протоколов + трафик-логи)

| Ресурс | Значение |
|--------|----------|
| **CPU** | 2 core |
| **RAM** | 512 MB |
| **Диск** | 5 GB (из них ~3-4 ГБ под traffic log) |

### Детализация RAM

| Компонент | RAM (idle) | RAM (peak) |
|-----------|-----------|-----------|
| Panel Core (Flask + SQLite) | ~30 MB | ~60 MB |
| Service Registry (Flask + SQLite) | ~20 MB | ~40 MB |
| Protocol Agent (Xray) | ~15 MB | ~30 MB |
| Protocol Agent (Hy2) | ~10 MB | ~20 MB |
| Protocol Agent (Caddy) | ~10 MB | ~20 MB |
| Traffic Collector (cron) | ~5 MB | ~15 MB |
| **Xray** (VLESS сервер) | ~20 MB | ~50 MB |
| **Hysteria 2** | ~10 MB | ~30 MB |
| **Caddy** | ~10 MB | ~20 MB |
| **AmneziaWG** | ~5 MB | ~10 MB |
| **Mieru** | ~10 MB | ~20 MB |
| **olcRTC** | ~15 MB | ~30 MB |

**Итого (пик, все компоненты):** ~345 MB

### Детализация диска

| Компонент | Диск |
|-----------|------|
| Panel Core + Registry (код) | ~5 MB |
| SQLite DB (1000 users + 1 год трафика) | ~100-500 MB |
| Xray бинарник | ~15 MB |
| Hysteria 2 бинарник | ~10 MB |
| Caddy бинарник | ~40 MB |
| AmneziaWG пакеты | ~10 MB |
| Mieru бинарник | ~10 MB |
| olcRTC бинарник | ~15 MB |
| **Traffic log (1 год, 100 users, daily stats)** | ~3-4 GB |
| Systemd логи (journald, ротация в 2 нед) | ~200 MB |

> Traffic log сильно зависит от ротации. Если хранить только за 30 дней — места нужно в 10 раз меньше (~300 MB).

---

## 4. Сеть

| Требование | Значение |
|-----------|----------|
| **IP-адрес** | IPv4 (обязательно), IPv6 (опционально) |
| **Открытые порты** | см. таблицу |
| **DNS** | A-запись на домен (или free домен от pxy) |
| **Доступ к Package Manager** | Для установки зависимостей |

### Порты

| Порт | Протокол | Назначение |
|------|----------|-----------|
| 22 | TCP | SSH |
| 80 | TCP | Caddy HTTP (редирект на HTTPS) |
| 443 | TCP | Xray VLESS+XHTTP+REALITY |
| 8443 | TCP | Caddy Panel + NaiveProxy (HTTPS) |
| 30000 | UDP | Hysteria 2 |
| 39743 | UDP | AmneziaWG |
| 444-448 | TCP | Mieru (5 портов) |
| 30001 | TCP | olcRTC WebSocket |
| 5000 | TCP | (локальный) Flask dev |
| 9001-9006 | TCP | (локальные) Protocol Agents API |

---

## 5. Права доступа

| Компонент | Требуемые права | Почему |
|-----------|----------------|--------|
| Panel Core | `root` | Чтение конфигов из `/etc/` |
| Protocol Agent Xray | `root` | systemctl restart xray, правка `/etc/xray/` |
| Protocol Agent Hy2 | `root` | systemctl restart hysteria-server |
| Protocol Agent Caddy | `root` | systemctl reload caddy, правка Caddyfile |
| Protocol Agent AWG | `root` | awg-quick, правка `/etc/amnezia/` |
| Protocol Agent Mieru | `root` | mita apply, правка `/etc/mita/` |
| Protocol Agent olcRTC | `root` | systemctl restart olcrtc, правка `/etc/olcrtc/` |
| Traffic Collector | `root` | Чтение nftables/iptables counters |

Агенты могут работать как systemd-сервисы под root, либо через sudo без пароля.

---

## 6. Программные интерфейсы

### Panel Core REST API (`/api/v1/`)

| Эндпоинт | Метод | Описание |
|----------|-------|----------|
| `/users` | GET/POST | Список / создать пользователя |
| `/users/{id}` | GET/PUT/DELETE | Данные пользователя |
| `/users/{id}/traffic` | GET | Трафик пользователя |
| `/services` | GET | Статус всех протоколов |
| `/services/{protocol}/users` | GET | Пользователи протокола |
| `/subscribe/{user}/{protocol}` | GET | Генерация подписочной ссылки |

### Service Registry API

| Эндпоинт | Метод | Описание |
|----------|-------|----------|
| `/register` | POST | Регистрация Protocol Agent |
| `/discover` | GET | Получить список агентов |
| `/health` | GET | Статус всех агентов и их сервисов |

### Protocol Agent API (единый для всех протоколов)

| Эндпоинт | Метод | Описание |
|----------|-------|----------|
| `/add_user` | POST | Создать пользователя |
| `/del_user` | POST | Удалить пользователя |
| `/list_users` | GET | Список пользователей |
| `/status` | GET | Статус протокола |
| `/stats/{user}` | GET | Трафик пользователя |
| `/config/{user}` | GET | Клиентский конфиг |

---

## 7. Установка

### Способ A: Всё сразу (через pxy)

1. Установить pxy на ПК
2. Ввести IP/пароль сервера
3. Нажать "Install" — pxy ставит всё через SSH

### Способ B: Панель отдельно (standalone)

```
# 1. Установить Python зависимости
pip install flask

# 2. Запустить Panel Core
python3 panel/app.py

# 3. Настроить Caddy reverse proxy
caddy reverse-proxy --to 127.0.0.1:5000 --from :8443
```

### Способ C: Protocol Agent отдельно

```
# Пример: Agent только для Xray
# 1. Убедиться что Xray установлен и работает
# 2. Запустить Agent рядом
python3 protocol_agent_xray/main.py --port 9001
# 3. Зарегистрировать в Service Registry
curl -X POST registry:8080/register \
  -H "Content-Type: application/json" \
  -d '{"protocol":"xray","host":"server-1","port":9001}'
```

---

## 8. Мониторинг и обслуживание

| Операция | Частота | Команда |
|----------|---------|---------|
| Ротация traffic log | daily | `find /var/lib/panel/traffic -mtime +90 -delete` |
| Ротация audit log | weekly | `find /var/lib/panel/audit -mtime +365 -delete` |
| Бэкап SQLite DB | daily | `cp panel.db panel.db.$(date +%Y%m%d)` |
| Бэкап конфигов | daily | `tar czf /backup/etc-$(date +%Y%m%d).tar.gz /etc/xray /etc/hysteria /etc/caddy /etc/amnezia /etc/mita /etc/olcrtc` |
| Проверка сертификатов | weekly | `openssl x509 -checkend 604800 -in /etc/proxy-certs/fullchain.pem` |

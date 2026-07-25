# Server

## Prod

| Параметр | Значение |
|----------|----------|
| IP | 31.76.8.29 |
| Хост | MyServer-1.play2go.cloud |
| Домен | 76t05pyu.ikill.baby → panel.kuban-forum.ru |
| OS | Ubuntu 22.04+ (предположительно) |
| Назначение | Рабочий, через него идут соединения |

## Dev (стенд)

| Параметр | Значение |
|----------|----------|
| IP | 2.26.51.8 |
| Хост | MyServer-stend.play2go.cloud |
| Домен | oootubww.ikill.baby |
| OS | Debian 13 (trixie) |
| Диск | 60 GB (55 GB свободно) |
| RAM | 4 GB |
| Установка | Через pxy (все 6 протоколов) |
| Назначение | Разработка и тестирование панели, olcbox, olcRTC |

### Правила работы с dev

- Dev — полигон, можно ломать и переустанавливать через pxy
- `bash proxy_manager.sh` на dev может не совпадать с prod
- После отладки на dev — rsync/scp на prod
- Prod конфиги и users.json не копировать на dev (разные пользователи)
- Собирать APK и exe на dev, копировать готовые бинарники на prod

## Скрипты

| Скрипт | Назначение |
|--------|-----------|
| `server/proxy_manager.sh` | Главный скрипт управления (v0.8) — все протоколы |
| `server/tmp_deploy_olcrtc.sh` | Деплой olcRTC бинарника |
| `server/tmp_add_user.sh` | Добавление Hy2 пользователя |
| `server/tmp_vless_mgr.sh` | Управление VLESS пользователями |
| `server/tmp_xray_fix.py` | Включение debug-логов Xray |

## Правила деплоя

- Новые скрипты сначала тестировать на `bash -n` / `python -m py_compile`
- Изменения в продакшн-скриптах только после подтверждения
- При изменении портов/протоколов — обновлять SERVER_CONFIG.md
- Все изменения в сервисах (systemd) — через `systemctl daemon-reload` после правки

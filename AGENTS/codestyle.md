# Code Style

## Комментарии в коде

Каждый логический блок кода должен содержать краткий комментарий о том, что он делает. Это нужно для быстрого понимания как человеком, так и AI-агентами.

### Для функций

```python
def add_user(username, protocols):
    # Создать пользователя в БД
    db.execute("INSERT INTO users ...")

    # Добавить на каждый протокол через Protocol Agent
    for proto in protocols:
        agent = registry.discover(proto)
        agent.add_user(username)
```

```bash
add_user() {
    # Проверить, не занято ли имя
    check_user_exists "$1" && return 1

    # Создать папку пользователя
    mkdir -p "$BASE_DIR/$1"

    # Инициализировать реестр
    echo "$1:$(date +%s)" >> "$REGISTRY_FILE"
}
```

```go
func handleAddUser(w http.ResponseWriter, r *http.Request) {
    // Парсинг запроса
    var req AddUserRequest
    json.NewDecoder(r.Body).Decode(&req)

    // Валидация
    if req.Username == "" {
        http.Error(w, "username required", 400)
        return
    }

    // Добавление пользователя в сервис
    err := service.AddUser(req.Username)
    if err != nil {
        http.Error(w, err.Error(), 500)
        return
    }

    // Ответ
    json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}
```

### Для длинных блоков / сложной логики

```python
# Этап 1: собрать метрики со всех протоколов
for agent in agents:
    stats[agent.protocol] = agent.collect_stats()

# Этап 2: агрегировать в дневную статистику
daily = aggregate_daily(stats)

# Этап 3: сохранить в SQLite
db.insert_traffic_log(daily)
```

### Когда НЕ нужны комментарии

```python
# ❌ Избыточно — очевидно из кода
x = x + 1  # увеличиваем x на 1

# ✅ Достаточно читабельно без комментария
total_users = len(db.query("SELECT * FROM users"))
```

## Принципы

- **Комментарий поясняет «почему» и «что», а не «как»** — «как» видно из кода
- **Один комментарий на 5-15 строк кода** — реже = слишком общо, чаще = шум
- **На русском** — проект для разработчика
- **Коротко** — 3-10 слов, без лишних деталей
- **Не дублировать код** — если переменная называется `add_user_to_protocols`, комментарий «добавить пользователя» не нужен

# Депл olcRTC + Panel на_prod

**Дата:** 2026-07-23
**Сервер:** `31.76.8.29` (MyServer-1.play2go.cloud) / `76t05pyu.ikill.baby`

---

## Что обновляется

### 1. olcRTC бинарник
- **Было:** Jul 16 build (45 MB, без claims)
- **Станет:** Jul 19 build с dev (31 MB, statically linked, с claims auth)
- **Источник:** `/root/pj/olcrtc/build/olcrtc-linux-amd64` с dev сервера

### 2. Panel (Flask)
- `app.py` — fix `api_traffic`: `days=0` фильтрует по username (был баг: All показывал трафик всех юзеров)
- `app.py` — download APK route → `OlcboxME-1.0.2.apk`
- Шаблоны — chart logic (prev/current period bars), i18n, encoding fixes

### 3. NOT обновляется
- `users.json` — **оставить как есть** на проде (юзеры используют сервис)
- `server.yaml` — конфиг уже содержит `users_file`, менять не нужно

---

## Порядок действий

### Шаг 0: Pre-flight проверка
```bash
# На prod — текущее состояние
ssh root@31.76.8.29
systemctl status olcrtc
cat /etc/olcrtc/users.json
cat /root/.config/olcrtc/server.yaml
```

### Шаг 1: Бэкап на prod
```bash
# Бэкап бинарника
cp /root/pj/olcrtc/build/olcrtc-linux-amd64 /root/pj/olcrtc/build/olcrtc-linux-amd64.bak

# Бэкап панели
cp /opt/proxy-panel/app.py /opt/proxy-panel/app.py.bak
cp -r /opt/proxy-panel/templates /opt/proxy-panel/templates.bak
```

### Шаг 2: Депл olcRTC бинарника
```bash
# С dev сервера (2.26.51.8) скопировать бинарник
scp root@2.26.51.8:/root/pj/olcrtc/build/olcrtc-linux-amd64 /root/pj/olcrtc/build/olcrtc-linux-amd64
chmod +x /root/pj/olcrtc/build/olcrtc-linux-amd64

# Перезапуск
systemctl restart olcrtc
sleep 2
systemctl is-active olcrtc
systemctl status olcrtc
```

### Шаг 3: Депл Panel
```bash
# С dev сервера скопировать app.py
scp root@2.26.51.8:/opt/proxy-panel/app.py /opt/proxy-panel/app.py

# Скопировать шаблоны (через Python для сохранения UTF-8)
scp root@2.26.51.8:/opt/proxy-panel/templates/self.html /opt/proxy-panel/templates/self.html
scp root@2.26.51.8:/opt/proxy-panel/templates/self_admin.html /opt/proxy-panel/templates/self_admin.html
scp root@2.26.51.8:/opt/proxy-panel/templates/index.html /opt/proxy-panel/templates/index.html

# ИЛИ через Python на prod (надёжнее для UTF-8):
python3 -c "
import urllib.request, base64
files = ['self.html', 'self_admin.html', 'index.html']
for f in files:
    url = 'http://2.26.51.8:5000/panel/api/v1/template/' + f  # если есть такой маршрут
    # Альтернатива: scp с -T для сохранения encoding
"
```

### Шаг 4: Перезапуск Flask
```bash
# Найти и убить текущий Flask
pkill -f 'python3 app.py'
sleep 1

# Запустить заново
cd /opt/proxy-panel && setsid python3 app.py > /tmp/panel.log 2>&1 < /dev/null & disown
sleep 2

# Проверить
ss -tlnp | grep 5000
tail -5 /tmp/panel.log
```

### Шаг 5: Верификация
```bash
# Проверка API
curl -s 'http://127.0.0.1:5000/panel/api/v1/traffic/<test_user>?days=0' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"All: {len(d)} rows")'
curl -s 'http://127.0.0.1:5000/panel/api/v1/traffic/<test_user>?days=4' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"Today: {len(d)} rows")'

# Проверка olcRTC
systemctl status olcrtc
journalctl -u olcrtc --since "1 min ago"

# Проверка веб-интерфейса
curl -sk https://76t05pyu.ikill.baby:8443/panel/self/ | head -20
```

### Шаг 6: Проверка APK
```bash
# Убедиться что APK доступен
curl -sk -o /dev/null -w "%{http_code}" https://76t05pyu.ikill.baby:8443/panel/static/OlcboxME-1.0.2.apk
# Должно быть 200
```

---

## Откат

### Если olcRTC не стартует:
```bash
cp /root/pj/olcrtc/build/olcrtc-linux-amd64.bak /root/pj/olcrtc/build/olcrtc-linux-amd64
systemctl restart olcrtc
```

### Если панель сломана:
```bash
cp /opt/proxy-panel/app.py.bak /opt/proxy-panel/app.py
cp -r /opt/proxy-panel/templates.bak/* /opt/proxy-panel/templates/
pkill -f 'python3 app.py'
cd /opt/proxy-panel && setsid python3 app.py > /tmp/panel.log 2>&1 < /dev/null & disown
```

---

## Заметки

- `users.json` на проде НЕ трогаем — юзеры используют olcRTC
- `server.yaml` уже содержит `auth.users_file: /etc/olcrtc/users.json` — не менять
- UTF-8 файлы (шаблоны) копировать через `scp -T` или Python, pscp на Windows ломает кодировку
- APK `OlcboxME-1.0.2.apk` уже лежит в `/opt/proxy-panel/static/` на dev

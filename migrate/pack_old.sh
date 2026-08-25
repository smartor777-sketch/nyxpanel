#!/bin/bash
# ==============================================================================
# NYX Panel — Migration pack script (run on OLD server)
# Пакетует ВСЁ состояние панели: панель, БД, юзеров, конфиги, сертификаты,
# бинарники, systemd-юниты — в один tar.gz для переноса на новый сервер.
#
# Использование:
#   bash pack_old.sh
#
# Результат: /root/nyx-migrate-<date>.tar.gz
# ==============================================================================
set -euo pipefail

SRC_DATE=$(date +%Y%m%d)
OUT="/root/nyx-migrate-${SRC_DATE}"
TAR="/root/nyx-migrate-${SRC_DATE}.tar.gz"

GREEN='\033[1;92m'; NC='\033[0m'
ok()  { echo -e "${GREEN}[OK]${NC} $*"; }

rm -rf "$OUT"
mkdir -p "$OUT"

echo "=== 1/9 Панель (app.py, collector.py, БД, шаблоны, статика) ==="
mkdir -p "$OUT/opt/proxy-panel"
rsync -a /opt/proxy-panel/ "$OUT/opt/proxy-panel/" \
  --exclude='__pycache__' --exclude='*.bak'
# Обрезаем WAL/SHM — SQLite восстановит их сам
rm -f "$OUT/opt/proxy-panel/panel.db-wal" "$OUT/opt/proxy-panel/panel.db-shm"
ok "panel.db + app.py + templates + static"

echo "=== 2/9 Юзеры и их конфиги ==="
mkdir -p "$OUT/root/proxy_users"
rsync -a /root/proxy_users/ "$OUT/root/proxy_users/"
ok "proxy_users/ (все конфиги/QR)"

echo "=== 3/9 proxy_manager.sh ==="
cp /root/proxy_manager.sh "$OUT/root/proxy_manager.sh"
ok "proxy_manager.sh"

echo "=== 4/9 Конфиги сервисов ==="
mkdir -p "$OUT/etc/hysteria" "$OUT/etc/sing-box" "$OUT/etc/olcrtc" \
         "$OUT/etc/mita" "$OUT/etc/amnezia/amneziawg" "$OUT/etc/xray" \
         "$OUT/etc/trojan-go" "$OUT/etc/caddy" "$OUT/usr/local/etc/xray"
cp /etc/hysteria/config.yaml "$OUT/etc/hysteria/config.yaml"
cp /etc/sing-box/config.json "$OUT/etc/sing-box/config.json"
cp /etc/sing-box/trojan_users.json "$OUT/etc/sing-box/trojan_users.json"
cp /etc/olcrtc/users.json "$OUT/etc/olcrtc/users.json"
cp /etc/olcrtc/server.yaml "$OUT/etc/olcrtc/server.yaml"
cp /etc/mita/server.json "$OUT/etc/mita/server.json"
cp /etc/amnezia/amneziawg/awg0.conf "$OUT/etc/amnezia/amneziawg/awg0.conf"
cp /etc/xray/users.json "$OUT/etc/xray/users.json"
cp /etc/trojan-go/config.json "$OUT/etc/trojan-go/config.json"
cp /usr/local/etc/xray/config.json "$OUT/usr/local/etc/xray/config.json"
cp /etc/caddy/Caddyfile "$OUT/etc/caddy/Caddyfile"
ok "hysteria/sing-box/olcrtc/mita/awg/xray/trojan/caddy"

echo "=== 5/9 Сертификаты ==="
mkdir -p "$OUT/etc/proxy-certs"
cp -r /etc/proxy-certs/* "$OUT/etc/proxy-certs/" 2>/dev/null || true
mkdir -p "$OUT/var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory"
cp -r /var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/panel.kuban-forum.ru \
      "$OUT/var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/" 2>/dev/null || true
ok "proxy-certs + caddy LE certs"

echo "=== 6/9 Бинарники ==="
mkdir -p "$OUT/usr/local/bin" "$OUT/usr/bin"
for b in xray sing-box caddy hysteria olcrtc trojan-go geoip.dat geosite.dat; do
  [ -f "/usr/local/bin/$b" ] && cp "/usr/local/bin/$b" "$OUT/usr/local/bin/" && ok "  /usr/local/bin/$b"
done
for b in mita awg awg-quick; do
  [ -f "/usr/bin/$b" ] && cp "/usr/bin/$b" "$OUT/usr/bin/" && ok "  /usr/bin/$b"
done

echo "=== 7/9 systemd-юниты ==="
mkdir -p "$OUT/etc/systemd/system"
for svc in caddy xray sing-box-naive hysteria2 olcrtc trojan-go panel; do
  [ -f "/etc/systemd/system/$svc.service" ] && cp "/etc/systemd/system/$svc.service" "$OUT/etc/systemd/system/" && ok "  $svc.service"
done
# mita/awg-quick — из deb, воспроизведём на новом сервере установкой пакетов
cp /usr/local/bin/service-watchdog.sh "$OUT/usr/local/bin/" 2>/dev/null || true
cp /usr/local/bin/sync-hy2-cert.sh "$OUT/usr/local/bin/" 2>/dev/null || true

echo "=== 8/9 Cron (watchdog + collector) ==="
crontab -l > "$OUT/crontab.txt" 2>/dev/null || true
ok "crontab"

echo "=== 9/9 Fallback-страница ==="
mkdir -p "$OUT/var/www/html"
cp -r /var/www/html/* "$OUT/var/www/html/" 2>/dev/null || true
ok "fallback"

echo "=== Пакуем ==="
cd "$OUT"
tar -czf "$TAR" .
cd /root
ok "Архив: $TAR"
ls -la "$TAR"

echo ""
echo "Скопируйте архив на новый сервер и выполните apply_new.sh"
#!/bin/bash
# ==============================================================================
# NYX Panel — Migration apply script (run on NEW server)
# Двухфазное развёртывание:
#   Фаза A: install.sh — ставит чистый стек (xray, caddy+forwardproxy, hysteria2,
#           mita, olcrtc, amneziawg-модуль, trojan-go, панель, юзеры, systemd).
#   Фаза B: наложение состояния со старого сервера (архив pack_old.sh) —
#           конфиги с серверными ключами, panel.db, proxy_users/, сертификаты.
# Ключевой принцип: НЕ пересоздаём юзеров/ключи — копируем серверное состояние,
# чтобы существующие конфиги клиентов продолжали работать.
#
# Использование (на новом сервере, от root):
#   bash apply_new.sh /root/nyx-migrate-<date>.tar.gz [новый_IP]
#   Пример: bash apply_new.sh /root/nyx-migrate-20260817.tar.gz 87.120.186.100
#
# После запуска: поменять A-запись panel.kuban-forum.ru на новый IP.
# ==============================================================================
set -euo pipefail

TAR="${1:?Укажите путь к архиву nyx-migrate-*.tar.gz}"
NEW_IP="${2:-$(curl -s ifconfig.me 2>/dev/null || echo '')}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"

DOMAIN="panel.kuban-forum.ru"
EMAIL="furi_wave@mail.ru"
GREEN='\033[1;92m'; YELLOW='\033[1;93m'; RED='\033[1;91m'; NC='\033[0m'
ok()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запускать от root"
[ -f "$TAR" ] || die "Архив не найден: $TAR"
[ "$(uname -m)" = "x86_64" ] || die "Только x86_64"

# -----------------------------------------------------------------------------
echo "=== Фаза A: базовая установка стека (install.sh) ==="
# -----------------------------------------------------------------------------
if [ "$SKIP_INSTALL" = "1" ] || [ -x /usr/local/bin/caddy ]; then
  warn "Стек уже установлен (или SKIP_INSTALL=1) — пропускаю install.sh"
else
  # upload install.sh со старым сервером? Скрипт скачивается с GitHub raw
  if [ ! -f /root/install.sh ]; then
    curl -sL "https://raw.githubusercontent.com/smartor777-sketch/nyxpanel/master/server/install.sh" -o /root/install.sh
  fi
  [ -s /root/install.sh ] || die "Не удалось скачать install.sh"
  chmod +x /root/install.sh
  DOMAIN="$DOMAIN" PANEL_PASS="admin" EMAIL="$EMAIL" bash /root/install.sh
  ok "install.sh выполнен"
fi

# -----------------------------------------------------------------------------
echo "=== Фаза B: остановка сервисов перед наложением состояния ==="
# -----------------------------------------------------------------------------
for svc in xray caddy sing-box-naive hysteria2 mita olcrtc trojan-go panel awg-quick@awg0; do
  systemctl stop "$svc" 2>/dev/null || true
done

# -----------------------------------------------------------------------------
echo "=== 1/6 Восстановление конфигов и данных ==="
# -----------------------------------------------------------------------------
base=$(mktemp -d)
tar -xzf "$TAR" -C "$base"

mkdir -p /opt/proxy-panel /root/proxy_users /etc/hysteria /etc/sing-box /etc/olcrtc \
         /etc/mita /etc/amnezia/amneziawg /etc/xray /etc/trojan-go /etc/caddy \
         /usr/local/etc/xray /etc/proxy-certs /var/www/html

# Панель (включая panel.db, шаблоны, статику)
[ -d "$base/opt/proxy-panel" ] && rsync -a "$base/opt/proxy-panel/" /opt/proxy-panel/
# Юзеры и их конфиги
[ -d "$base/root/proxy_users" ] && rsync -a "$base/root/proxy_users/" /root/proxy_users/
[ -f "$base/root/proxy_manager.sh" ] && cp "$base/root/proxy_manager.sh" /root/proxy_manager.sh && chmod 700 /root/proxy_manager.sh
# Конфиги сервисов
[ -f "$base/etc/hysteria/config.yaml" ]          && cp "$base/etc/hysteria/config.yaml" /etc/hysteria/
[ -f "$base/etc/sing-box/config.json" ]          && cp "$base/etc/sing-box/config.json" /etc/sing-box/
[ -f "$base/etc/sing-box/trojan_users.json" ]    && cp "$base/etc/sing-box/trojan_users.json" /etc/sing-box/
[ -f "$base/etc/olcrtc/users.json" ]             && cp "$base/etc/olcrtc/users.json" /etc/olcrtc/
[ -f "$base/etc/olcrtc/server.yaml" ]            && cp "$base/etc/olcrtc/server.yaml" /etc/olcrtc/
[ -f "$base/etc/mita/server.json" ]              && cp "$base/etc/mita/server.json" /etc/mita/
[ -f "$base/etc/amnezia/amneziawg/awg0.conf" ]   && cp "$base/etc/amnezia/amneziawg/awg0.conf" /etc/amnezia/amneziawg/
[ -f "$base/etc/xray/users.json" ]               && cp "$base/etc/xray/users.json" /etc/xray/
[ -f "$base/etc/trojan-go/config.json" ]         && cp "$base/etc/trojan-go/config.json" /etc/trojan-go/
[ -f "$base/usr/local/etc/xray/config.json" ]    && cp "$base/usr/local/etc/xray/config.json" /usr/local/etc/xray/
[ -f "$base/etc/caddy/Caddyfile" ]               && cp "$base/etc/caddy/Caddyfile" /etc/caddy/
# Сертификаты
[ -d "$base/etc/proxy-certs" ] && cp -r "$base/etc/proxy-certs/." /etc/proxy-certs/ 2>/dev/null || true
mkdir -p /var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory
[ -d "$base/var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/panel.kuban-forum.ru" ] && \
  cp -r "$base/var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/panel.kuban-forum.ru" \
        /var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/
# Fallback-страница
[ -d "$base/var/www/html" ] && rsync -a "$base/var/www/html/" /var/www/html/
# systemd-юниты (важно: caddy.service под caddy user + XDG_DATA_HOME=/var/lib/caddy)
mkdir -p /etc/systemd/system
[ -d "$base/etc/systemd/system" ] && cp -f "$base/etc/systemd/system/"*.service /etc/systemd/system/ 2>/dev/null || true
# Бинарники (если в архиве есть — точное совпадение версий со старым сервером)
[ -d "$base/usr/local/bin" ] && cp -f "$base/usr/local/bin/"* /usr/local/bin/ 2>/dev/null || true
[ -d "$base/usr/bin" ] && cp -f "$base/usr/bin/"* /usr/bin/ 2>/dev/null || true
rm -rf "$base"

chmod 600 /etc/amnezia/amneziawg/awg0.conf 2>/dev/null || true
chown root:olcrtc /etc/olcrtc/server.yaml /etc/olcrtc/users.json 2>/dev/null || true
chmod 640 /etc/olcrtc/server.yaml /etc/olcrtc/users.json 2>/dev/null || true
chown -R hysteria:hysteria /etc/proxy-certs 2>/dev/null || true
chown -R caddy:caddy /var/lib/caddy 2>/dev/null || true
chmod 755 /usr/local/bin/xray /usr/local/bin/sing-box /usr/local/bin/caddy \
          /usr/local/bin/hysteria /usr/local/bin/olcrtc /usr/local/bin/trojan-go 2>/dev/null || true

# Убираем из Caddyfile блоки ДРУГИХ приложений (sleep.kuban-forum.ru остаётся на старом сервере)
if [ -f /etc/caddy/Caddyfile ]; then
  python3 - <<'PYEOF'
import re, pathlib
p = pathlib.Path('/etc/caddy/Caddyfile')
text = p.read_text()
# Удаляем блок sleep.kuban-forum.ru { ... }
text = re.sub(r'\n?sleep\.kuban-forum\.ru\s*\{.*?\n\}\n', '\n', text, flags=re.S)
p.write_text(text)
print("Caddyfile очищен от sleep.kuban-forum.ru")
PYEOF
fi
ok "конфиги/данные/бинарники восстановлены"

# -----------------------------------------------------------------------------
echo "=== 2/6 Правка proxy_manager.sh под новый IP ==="
# -----------------------------------------------------------------------------
if [ -n "$NEW_IP" ]; then
  sed -i "s/MIERU_IP=\".*\"/MIERU_IP=\"$NEW_IP\"/" /root/proxy_manager.sh || true
  grep -q "SERVER_DOMAIN=\"$DOMAIN\"" /root/proxy_manager.sh || \
    sed -i "s/SERVER_DOMAIN=\".*\"/SERVER_DOMAIN=\"$DOMAIN\"/" /root/proxy_manager.sh
  ok "MIERU_IP=$NEW_IP, SERVER_DOMAIN=$DOMAIN"
else
  warn "MIERU_IP не изменён (не определён IP)"
fi

# -----------------------------------------------------------------------------
echo "=== 3/6 Пользователи, юниты и сервисы ==="
# -----------------------------------------------------------------------------
# Пользователи под сервисы (нужны для скопированных systemd-юнитов)
groupadd -r nyxcerts 2>/dev/null || true
for u in caddy hysteria singbox olcrtc trojan mita; do
  id "$u" &>/dev/null || useradd -r -M -s /usr/sbin/nologin "$u" 2>/dev/null || true
done
id olcrtc &>/dev/null || useradd -r -M -U -s /usr/sbin/nologin -d /var/lib/olcrtc olcrtc 2>/dev/null || true
usermod -aG nyxcerts singbox 2>/dev/null || true
usermod -aG nyxcerts trojan 2>/dev/null || true
mkdir -p /var/lib/olcrtc/data
chown -R olcrtc:olcrtc /var/lib/olcrtc 2>/dev/null || true
ok "пользователи созданы"

# mita и awg-quick — от deb/install.sh, юниты уже на месте
systemctl daemon-reload
for svc in xray caddy sing-box-naive hysteria2 mita olcrtc trojan-go panel; do
  if systemctl cat "$svc.service" &>/dev/null; then
    systemctl enable "$svc" 2>/dev/null || true
    systemctl start "$svc" 2>/dev/null && ok "  $svc started" || warn "  $svc FAILED"
  else
    warn "  $svc: юнит не найден"
  fi
done

# AmneziaWG
if [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
  systemctl enable awg-quick@awg0 2>/dev/null || true
  systemctl restart awg-quick@awg0 2>/dev/null && ok "  awg-quick@awg0 started" || warn "  awg-quick@awg0 FAILED (проверьте kernel module amneziawg: modprobe amneziawg)"
fi

# -----------------------------------------------------------------------------
echo "=== 4/6 Watchdog + collector cron ==="
# -----------------------------------------------------------------------------
[ -f /usr/local/bin/service-watchdog.sh ] && chmod +x /usr/local/bin/service-watchdog.sh
[ -f /usr/local/bin/sync-hy2-cert.sh ] && chmod +x /usr/local/bin/sync-hy2-cert.sh
(crontab -l 2>/dev/null || true; echo "*/5 * * * * python3 /opt/proxy-panel/collector.py >> /var/log/panel-collector.log 2>&1") | sort -u | crontab - || true
(crontab -l 2>/dev/null || true; echo "*/5 * * * * /usr/local/bin/service-watchdog.sh") | sort -u | crontab - || true
ok "cron настроен"

# -----------------------------------------------------------------------------
echo "=== 5/6 Fallback для Trojan (порт 8080 в Caddyfile) ==="
# -----------------------------------------------------------------------------
if ! grep -q "http://.*:8080" /etc/caddy/Caddyfile 2>/dev/null; then
  warn "Нет http://:8080 блока — trojan fallback может не работать. Добавьте его вручную."
fi
if ! grep -q "$DOMAIN:443" /etc/caddy/Caddyfile 2>/dev/null; then
  warn "В Caddyfile нет $DOMAIN:443 — панель не будет доступна по HTTPS!"
fi

# -----------------------------------------------------------------------------
echo "=== 6/6 Итоговые проверки ==="
# -----------------------------------------------------------------------------
for svc in xray caddy sing-box-naive hysteria2 mita olcrtc trojan-go panel; do
  echo "  $svc: $(systemctl is-active "$svc" 2>/dev/null || echo 'n/a')"
done
echo "  awg0: $(ip link show awg0 2>/dev/null | head -1 | awk '{print $2}' || echo down)"

echo ""
echo -e "${GREEN}=============================================================${NC}"
echo -e "Развёртывание завершено. Дальше:"
echo -e " 1. ${YELLOW}Поменять A-запись${NC} $DOMAIN -> $NEW_IP (TTL ~512s)"
echo -e " 2. Проверить https://$DOMAIN/self/login (admin/пароль из старой БД)"
echo -e " 3. Проверить каждый протокол: vless :4433, hy2 :30000, naive :8443,"
echo -e "    mieru :444-448, trojan :9443, awg/olcrtc :39743"
echo -e " 4. Обновить .env: SERVER_IP=$NEW_IP, PANEL_URL=https://$DOMAIN/self/login"
echo -e " 5. Старый сервер 31.76.8.29 продолжит работать, пока не переключите DNS"
echo -e "${GREEN}=============================================================${NC}"
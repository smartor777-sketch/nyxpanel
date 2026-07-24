#!/bin/bash
# ==============================================================================
# NYX Panel — Auto-Install Script v2
# Устанавливает полный стек: xray, caddy, hysteria2, mieru, olcrtc, awg + панель
# На чистом Debian 12/13 (trixie/bookworm)
# ==============================================================================
set -euo pipefail

RED='\033[1;91m'; GREEN='\033[1;92m'; YELLOW='\033[1;93m'; CYAN='\033[1;96m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

DOMAIN="${DOMAIN:-}"
PANEL_PASS="${PANEL_PASS:-admin}"
EMAIL="${EMAIL:-furi_wave@mail.ru}"

VLESS_PORT="${VLESS_PORT:-4433}"
HY2_PORT="${HY2_PORT:-30000}"
MIERU_PORTS="${MIERU_PORTS:-444-448}"
OLCRTC_PORT="${OLCRTC_PORT:-39743}"
PANEL_PORT="${PANEL_PORT:-5000}"

XRAY_VERSION="${XRAY_VERSION:-26.3.27}"
HYSTERIA_VERSION="${HYSTERIA_VERSION:-2.10.0}"

if [ "$(id -u)" -ne 0 ]; then error "Запускать от root"; fi
if [ -z "$DOMAIN" ]; then
    read -p "Введите домен: " DOMAIN
    [ -z "$DOMAIN" ] && error "Домен обязателен"
fi
info "Домен: $DOMAIN"

ARCH=$(uname -m)
[ "$ARCH" != "x86_64" ] && error "Только x86_64"

# --- 1. Базовая настройка ---
info "=== Шаг 1: Базовая настройка ==="
export DEBIAN_FRONTEND=noninteractive

# Очистка битых пакетов (mita и др., которые могли остаться от прошлых установок)
dpkg --purge --force-depends mita 2>/dev/null || true
rm -f /var/lib/dpkg/info/mita.*
apt-get -f -y install 2>/dev/null || true

apt-get update -qq
apt-get install -y -qq curl wget jq qrencode unzip python3 python3-pip ufw gnupg2 lsb-release ca-certificates socat net-tools htop > /dev/null 2>&1

# Swap 2GB
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile > /dev/null && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl vm.swappiness=10 > /dev/null
    info "Swap 2GB создан"
fi

# UFW (без --force reset на чистой системе)
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 80/tcp > /dev/null 2>&1
ufw allow 443/tcp > /dev/null 2>&1
ufw allow ${VLESS_PORT}/tcp > /dev/null 2>&1
ufw allow 8443/tcp > /dev/null 2>&1
ufw allow ${HY2_PORT}/udp > /dev/null 2>&1
# UFW использует двоеточие для диапазонов портов (не дефис)
ufw allow ${MIERU_PORTS//-/:}/tcp > /dev/null 2>&1
ufw allow ${OLCRTC_PORT}/udp > /dev/null 2>&1
ufw allow ${OLCRTC_PORT}/tcp > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
info "UFW настроен"

# --- 2. Xray (VLESS + Reality) ---
info "=== Шаг 2: Установка Xray ==="

cd /tmp
curl -sL "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip" -o xray.zip
unzip -oq xray.zip -d xray_tmp
install -m 755 xray_tmp/xray /usr/local/bin/xray
cp xray_tmp/geoip.dat /usr/local/bin/geoip.dat 2>/dev/null || true
cp xray_tmp/geosite.dat /usr/local/bin/geosite.dat 2>/dev/null || true
mkdir -p /usr/local/etc/xray /var/log/xray
rm -rf xray_tmp xray.zip

# Если geoip не в зипе — скачиваем отдельно
if [ ! -f /usr/local/bin/geoip.dat ]; then
    curl -sL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -o /usr/local/bin/geoip.dat
    curl -sL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -o /usr/local/bin/geosite.dat
fi

REALITY_KEYS=$(/usr/local/bin/xray x25519)
REALITY_PRIVATE=$(echo "$REALITY_KEYS" | grep "^PrivateKey" | awk '{print $2}')
REALITY_PUBLIC=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)

cat > /usr/local/etc/xray/config.json << XRAY_EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "/vless" },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "1.1.1.1:443",
          "serverNames": ["", "1.1.1.1", "${DOMAIN}"],
          "privateKey": "${REALITY_PRIVATE}",
          "shortIds": ["${SHORT_ID}", ""]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "tag": "vless"
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "outboundTag": "block", "ip": ["geoip:private"] }
    ]
  }
}
XRAY_EOF

cat > /etc/systemd/system/xray.service << 'SVCEOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755
[Install]
WantedBy=multi-user.target
SVCEOF

chown nobody:nogroup /var/log/xray
mkdir -p /etc/xray
echo '{}' > /etc/xray/users.json
systemctl daemon-reload
systemctl enable --now xray
info "Xray установлен (PK: ${REALITY_PUBLIC})"

# --- 3. Caddy ---
info "=== Шаг 3: Установка Caddy ==="

apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https > /dev/null 2>&1
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
apt-get update -qq > /dev/null 2>&1

# Переустановка, если бинарник отсутствует (например, после ручной зачистки)
if ! command -v caddy &>/dev/null; then
    dpkg --purge caddy 2>/dev/null || true
    apt-get install -y -qq caddy > /dev/null 2>&1
else
    apt-get install -y -qq caddy > /dev/null 2>&1
fi

PANEL_PASS_HASH=$(caddy hash-password --plaintext "$PANEL_PASS" 2>/dev/null || echo 'CHANGEME')

cat > /etc/caddy/Caddyfile << CADDY_EOF
{
    email ${EMAIL}
}

${DOMAIN}:443, ${DOMAIN}:8443 {
    handle /panel/api/* {
        reverse_proxy 127.0.0.1:${PANEL_PORT}
    }

    handle /panel* {
        basicauth {
            admin ${PANEL_PASS_HASH}
        }
        reverse_proxy 127.0.0.1:${PANEL_PORT}
    }

    handle /self* {
        reverse_proxy 127.0.0.1:${PANEL_PORT}
    }

    handle /static/* {
        root * /opt/proxy-panel
        file_server
    }

    handle / {
        redir /self/login 302
    }
}
CADDY_EOF

systemctl enable --now caddy
info "Caddy установлен"

# --- 4. Hysteria 2 ---
info "=== Шаг 4: Установка Hysteria 2 ==="

HY2_URL="https://github.com/apernet/hysteria/releases/download/app%2Fv${HYSTERIA_VERSION}/hysteria-linux-amd64"
curl -sL "$HY2_URL" -o /usr/local/bin/hysteria
chmod 755 /usr/local/bin/hysteria

OBFSC_PASS=$(openssl rand -hex 16)
INIT_PASS=$(openssl rand -hex 12)

mkdir -p /etc/hysteria /etc/proxy-certs
cat > /etc/hysteria/config.json << HY2_EOF
{
  "listen": ":${HY2_PORT}",
  "tls": {
    "cert": "/etc/proxy-certs/fullchain.pem",
    "key": "/etc/proxy-certs/privkey.pem"
  },
  "auth": {
    "type": "userpass",
    "userpass": {
      "initial_user": "${INIT_PASS}"
    }
  },
  "obfs": {
    "type": "salamander",
    "salamander": {
      "password": "${OBFSC_PASS}"
    }
  }
}
HY2_EOF

openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/proxy-certs/privkey.pem \
    -out /etc/proxy-certs/fullchain.pem \
    -subj "/CN=${DOMAIN}" 2>/dev/null
chown -R hysteria:hysteria /etc/proxy-certs 2>/dev/null || true
chmod 640 /etc/proxy-certs/*.pem

cat > /etc/systemd/system/hysteria2.service << 'SVCEOF'
[Unit]
Description=Hysteria 2 Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.json
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now hysteria2
info "Hysteria 2 установлен"

# --- 5. Mieru (mita) ---
info "=== Шаг 5: Установка Mieru ==="

# mita — серверный бинарник (отдельный от mieru клиента)
MITA_URL="https://github.com/enfein/mieru/releases/download/v3.34.1/mita_3.34.1_amd64.deb"
curl -sL "$MITA_URL" -o /tmp/mita.deb
dpkg -i /tmp/mita.deb 2>/dev/null || true
rm -f /tmp/mita.deb
apt-get -f -y install 2>/dev/null || true

# Исправляем mita.service если бинарник /usr/bin/mita а не /usr/bin/mieru
if [ -f /usr/bin/mita ] && ! [ -f /usr/bin/mieru ]; then
    # Удаляем потенциальный конфликт с клиентом mieru
    dpkg -r mieru 2>/dev/null || true
    # Патчим сервис если ссылается на несуществующий /usr/bin/mieru
    if grep -q "/usr/bin/mieru" /lib/systemd/system/mita.service 2>/dev/null; then
        sed -i 's|/usr/bin/mieru|/usr/bin/mita|g' /lib/systemd/system/mita.service
    fi
fi

mkdir -p /etc/mita /var/run/mita
if [ ! -f /etc/mita/server.json ]; then
    cat > /etc/mita/server.json << MIERU_EOF
{
  "portBindings": [{ "portRange": "${MIERU_PORTS}", "protocol": "TCP" }],
  "users": [],
  "loggingLevel": "INFO",
  "mtu": 1400
}
MIERU_EOF
fi

# Применяем конфиг (нужен запущенный mita daemon)
mita apply config /etc/mita/server.json 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now mita 2>/dev/null || true
info "Mieru установлен (mita $(mita version 2>/dev/null || echo '?'))"

# --- 6. olcRTC ---
info "=== Шаг 6: Установка olcRTC ==="
mkdir -p /usr/local/bin /root/.config/olcrtc /etc/olcrtc

# Скачиваем бинарник с GitHub releases
OLCRTC_URL="https://github.com/smartor777-sketch/olcrtc-users/releases/download/latest/olcrtc-linux-amd64"
curl -sL "$OLCRTC_URL" -o /usr/local/bin/olcrtc
chmod 755 /usr/local/bin/olcrtc

# Проверяем что бинарник валидный (> 1MB)
OLCRTC_SIZE=$(stat -c%s /usr/local/bin/olcrtc 2>/dev/null || echo 0)
if [ "$OLCRTC_SIZE" -lt 1000000 ]; then
    warn "olcrtc: невалидный бинарник (${OLCRTC_SIZE} bytes), пропускаем"
    rm -f /usr/local/bin/olcrtc
else
    info "olcrtc установлен"
fi

cat > /root/.config/olcrtc/server.yaml << OLRTC_EOF
mode: srv
auth:
  users_file: /etc/olcrtc/users.json
  provider: jitsi
room:
  id: "https://meet.egovm.ru/${DOMAIN}"
crypto:
  key: "$(openssl rand -hex 32)"
net:
  transport: datachannel
  dns: "8.8.8.8:53"
liveness:
  interval: 10s
  timeout: 5s
  failures: 3
data: data
debug: false
OLRTC_EOF

echo '{}' > /etc/olcrtc/users.json

cat > /etc/systemd/system/olcrtc.service << 'SVCEOF'
[Unit]
Description=olcrtc server
After=network-online.target
[Service]
Type=simple
WorkingDirectory=/root
ExecStart=/usr/local/bin/olcrtc /root/.config/olcrtc/server.yaml
Restart=always
RestartSec=5s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now olcrtc 2>/dev/null || true

# --- 7. AmneziaWG ---
info "=== Шаг 7: Установка AmneziaWG ==="

# AmneziaWG есть в репозиториях Debian 13 (trixie) — PPA не нужен
apt-get install -y -qq amneziawg amneziawg-tools 2>/dev/null || {
    warn "amneziawg не установлен через apt"
}

# Если DKMS не собрался — пересобрать
if ! lsmod | grep -q amneziawg; then
    dkms autoinstall 2>/dev/null || true
    modprobe awg 2>/dev/null || true
fi

if command -v awg &>/dev/null; then
    AWG_SERVER_PRIV=$(awg genkey)
    NET_IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

    mkdir -p /etc/amnezia/amneziawg
    cat > /etc/amnezia/amneziawg/awg0.conf << AWG_EOF
[Interface]
PrivateKey = ${AWG_SERVER_PRIV}
Address = 10.9.9.1/24
ListenPort = ${OLCRTC_PORT}
Jc = 3
Jmin = 62
Jmax = 157
S1 = 49
S2 = 54
S3 = 9
S4 = 12
H1 = 168771320-311865390
H2 = 404210777-749860699
H3 = 974164843-1203785257
H4 = 1253151579-2031452500
I1 = <r 150>
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -t nat -A POSTROUTING -o ${NET_IFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ${NET_IFACE} -j MASQUERADE
AWG_EOF

    awg-quick down awg0 2>/dev/null || true
    awg-quick up awg0 2>/dev/null || true
    systemctl enable awg-quick@awg0 2>/dev/null || true
    info "AmneziaWG установлен"
else
    warn "AmneziaWG не установлен"
fi

# --- 8. Панель + proxy_manager.sh ---
info "=== Шаг 8: Установка панели ==="

pip3 install flask --break-system-packages 2>/dev/null || pip3 install flask

INSTALL_DIR="/opt/proxy-panel"
mkdir -p "$INSTALL_DIR/templates" "$INSTALL_DIR/static" "$INSTALL_DIR/samples"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_DIR="${SCRIPT_DIR}/../panel/proxy-panel"
REPO_URL="https://raw.githubusercontent.com/smartor777-sketch/nyxpanel/master"

# Копируем из локального репозитория или скачиваем с GitHub
if [ -d "$PANEL_DIR" ]; then
    cp "$PANEL_DIR/app.py" "$INSTALL_DIR/app.py"
    cp "$PANEL_DIR/collector.py" "$INSTALL_DIR/collector.py" 2>/dev/null || true
    cp "$PANEL_DIR/templates/"* "$INSTALL_DIR/templates/" 2>/dev/null || true
    cp "$PANEL_DIR/static/"* "$INSTALL_DIR/static/" 2>/dev/null || true
    info "Панель скопирована из репозитория"
else
    info "Скачиваем панель с GitHub..."
    curl -sL "${REPO_URL}/panel/proxy-panel/app.py" -o "$INSTALL_DIR/app.py"
    curl -sL "${REPO_URL}/panel/proxy-panel/collector.py" -o "$INSTALL_DIR/collector.py"
    # Скачиваем шаблоны и статику
    for f in $(curl -sL "https://api.github.com/repos/smartor777-sketch/nyxpanel/contents/panel/proxy-panel/templates" | python3 -c "import sys,json; [print(x['name']) for x in json.load(sys.stdin) if x['type']=='file']" 2>/dev/null); do
        curl -sL "${REPO_URL}/panel/proxy-panel/templates/$f" -o "$INSTALL_DIR/templates/$f"
    done
    for f in $(curl -sL "https://api.github.com/repos/smartor777-sketch/nyxpanel/contents/panel/proxy-panel/static" | python3 -c "import sys,json; [print(x['name']) for x in json.load(sys.stdin) if x['type']=='file']" 2>/dev/null); do
        curl -sL "${REPO_URL}/panel/proxy-panel/static/$f" -o "$INSTALL_DIR/static/$f"
    done
    info "Панель скачана с GitHub"
fi

# proxy_manager.sh
if [ -f "$SCRIPT_DIR/proxy_manager.sh" ]; then
    cp "$SCRIPT_DIR/proxy_manager.sh" /root/proxy_manager.sh
    chmod +x /root/proxy_manager.sh
    info "proxy_manager.sh скопирован из репозитория"
else
    info "Скачиваем proxy_manager.sh с GitHub..."
    curl -sL "${REPO_URL}/server/proxy_manager.sh" -o /root/proxy_manager.sh
    chmod +x /root/proxy_manager.sh
    info "proxy_manager.sh скачан с GitHub"
fi

cat > /etc/systemd/system/panel.service << 'SVCEOF'
[Unit]
Description=Proxy Panel
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/proxy-panel
ExecStart=/usr/bin/python3 /opt/proxy-panel/app.py
Restart=always
RestartSec=5s
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now panel 2>/dev/null || warn "Панель не запущена (нет app.py?)"

# --- 9. Watchdog ---
info "=== Шаг 9: Service Watchdog ==="

cat > /usr/local/bin/service-watchdog.sh << 'WDEOF'
#!/bin/bash
SERVICES="xray caddy hysteria2 mita olcrtc awg-quick@awg0"
LOG="/var/log/service-watchdog.log"
MAX_LOG_LINES=1000
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }
rotate_log() {
    if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$MAX_LOG_LINES" ]; then
        tail -n $((MAX_LOG_LINES / 2)) "$LOG" > "${LOG}.tmp"; mv "${LOG}.tmp" "$LOG"
    fi
}
restarted=0
for svc in $SERVICES; do
    systemctl cat "${svc}.service" &>/dev/null || continue
    status=$(systemctl is-active "$svc" 2>/dev/null)
    [ "$status" = "active" ] && continue
    log "WARN: $svc is $status — restarting"
    systemctl restart "$svc"; sleep 2
    new_status=$(systemctl is-active "$svc" 2>/dev/null)
    [ "$new_status" = "active" ] && log "OK: $svc restarted" || log "ERROR: $svc restart failed"
    restarted=$((restarted + 1))
done
[ "$restarted" -eq 0 ] && log "OK: all services active"
rotate_log
WDEOF

chmod +x /usr/local/bin/service-watchdog.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/service-watchdog.sh") | sort -u | crontab -
info "Watchdog установлен"

# --- 10. LE + cert sync ---
info "=== Шаг 10: Let's Encrypt ==="
systemctl stop caddy 2>/dev/null || true
apt-get install -y -qq certbot > /dev/null 2>&1

certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --http-01-port 80 2>/dev/null && {
    cp /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem /etc/proxy-certs/fullchain.pem
    cp /etc/letsencrypt/live/"$DOMAIN"/privkey.pem /etc/proxy-certs/privkey.pem
    chown -R hysteria:hysteria /etc/proxy-certs 2>/dev/null || true
    systemctl restart hysteria2
    info "LE-сертификат получен"
} || warn "LE не сработал. Self-signed cert используется."

systemctl start caddy

cat > /usr/local/bin/sync-hy2-cert.sh << 'CERT_EOF'
#!/bin/bash
CERT_DIR="/etc/letsencrypt/live"
DOMAIN=$(ls "$CERT_DIR" 2>/dev/null | head -1)
[ -z "$DOMAIN" ] && exit 0
SRC="$CERT_DIR/$DOMAIN"; DST="/etc/proxy-certs"; CHANGED=0
[ -f "$SRC/fullchain.pem" ] && [ "$SRC/fullchain.pem" -nt "$DST/fullchain.pem" ] && cp "$SRC/fullchain.pem" "$DST/fullchain.pem" && CHANGED=1
[ -f "$SRC/privkey.pem" ] && [ "$SRC/privkey.pem" -nt "$DST/privkey.pem" ] && cp "$SRC/privkey.pem" "$DST/privkey.pem" && CHANGED=1
[ "$CHANGED" -eq 1 ] && chown hysteria:hysteria "$DST"/*.pem 2>/dev/null && systemctl restart hysteria2 && echo "$(date) Synced cert" >> /var/log/hy2-cert-sync.log
CERT_EOF
chmod +x /usr/local/bin/sync-hy2-cert.sh

cat > /etc/systemd/system/sync-hy2-cert.timer << 'TMREOF'
[Unit]
Description=Sync Caddy cert to Hysteria2
[Timer]
OnBootSec=5min
OnUnitActiveSec=12h
[Install]
WantedBy=timers.target
TMREOF

cat > /etc/systemd/system/sync-hy2-cert.service << 'SVCEOF'
[Unit]
Description=Sync Caddy cert to Hysteria2
[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-hy2-cert.sh
SVCEOF

systemctl daemon-reload
systemctl enable --now sync-hy2-cert.timer

# --- Готово ---
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  NYX Panel — Установка завершена!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "Панель: ${CYAN}https://${DOMAIN}:8443/panel/${NC}"
echo -e "Логин:  ${CYAN}admin${NC}  Пароль: ${CYAN}${PANEL_PASS}${NC}"
echo -e "Reality PK: ${YELLOW}${REALITY_PUBLIC}${NC}"
echo -e "Short ID:   ${YELLOW}${SHORT_ID}${NC}"
echo -e "Hy2 obfs:   ${YELLOW}${OBFSC_PASS}${NC}"
echo -e "Hy2 init:   ${YELLOW}initial_user:${INIT_PASS}${NC}"
echo ""
echo -e "Сервисы:"
for svc in xray caddy hysteria2 mita olcrtc panel; do
    echo -e "  $svc: ${CYAN}$(systemctl is-active $svc 2>/dev/null || echo 'n/a')${NC}"
done

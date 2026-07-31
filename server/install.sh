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
apt-get install -y -qq curl wget jq yq qrencode unzip python3 python3-pip ufw gnupg2 lsb-release ca-certificates socat net-tools htop > /dev/null 2>&1

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
ufw allow 8080/tcp > /dev/null 2>&1
ufw allow ${VLESS_PORT}/tcp > /dev/null 2>&1
ufw allow 8443/tcp > /dev/null 2>&1
ufw allow ${HY2_PORT}/udp > /dev/null 2>&1
# UFW использует двоеточие для диапазонов портов (не дефис)
ufw allow ${MIERU_PORTS//-/:}/tcp > /dev/null 2>&1
ufw allow ${OLCRTC_PORT}/udp > /dev/null 2>&1
ufw allow ${OLCRTC_PORT}/tcp > /dev/null 2>&1
ufw allow 9443/tcp > /dev/null 2>&1
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

# --- 3. NaiveProxy + sing-box ---
info "=== Шаг 3: Установка NaiveProxy (sing-box) ==="

SINGBOX_VERSION="1.12.4"
curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz" -o /tmp/sing-box.tar.gz
tar xzf /tmp/sing-box.tar.gz -C /tmp
install -m 755 /tmp/sing-box-${SINGBOX_VERSION}-linux-amd64/sing-box /usr/local/bin/sing-box
rm -rf /tmp/sing-box*
info "sing-box v${SINGBOX_VERSION} установлен"

NAIVE_PASSWORD=$(openssl rand -hex 12)
mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json << SB_EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive",
      "listen": "::",
      "listen_port": 8443,
      "users": [
        {
          "username": "initial",
          "password": "${NAIVE_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
        "key_path": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
      }
    }
  ]
}
SB_EOF

cat > /etc/systemd/system/sing-box-naive.service << 'SVCEOF'
[Unit]
Description=sing-box NaiveProxy server
After=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now sing-box-naive
info "sing-box NaiveProxy установлен на порту 8443"

# --- 3b. Caddy (forward_proxy + панель + fallback) ---
info "=== Шаг 3b: Caddy сборка с forwardproxy ==="

GO_VERSION="${GO_VERSION:-1.25.12}"
CADDY_FORWARD_VERSION="${CADDY_FORWARD_VERSION:-latest}"

# Go (устанавливаем/обновляем до нужной версии)
rm -rf /usr/local/go
curl -sL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
tar -C /usr/local -xzf /tmp/go.tar.gz
export PATH=$PATH:/usr/local/go/bin
echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
rm -f /tmp/go.tar.gz
info "Go ${GO_VERSION} установлен"

export PATH=$PATH:/root/go/bin:/usr/local/go/bin

# xcaddy
if ! command -v xcaddy &>/dev/null; then
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
fi

# Сборка Caddy с forwardproxy
xcaddy build --with github.com/caddyserver/forwardproxy@${CADDY_FORWARD_VERSION} --output /usr/local/bin/caddy
info "Caddy собран с forwardproxy $(caddy version 2>/dev/null || true)"

cat > /etc/systemd/system/caddy.service << 'SVCEOF'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target
[Service]
Type=notify
User=root
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
SVCEOF

mkdir -p /etc/caddy /var/www/html

# Fallback-страница (фейк)
cat > /var/www/html/index.html << 'FALLBACK'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ООО "НКТ-Консалтинг" — Аудит и бухгалтерское сопровождение</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:system-ui,-apple-system,sans-serif;background:#f5f5f5;color:#333;display:flex;flex-direction:column;min-height:100vh}
header{background:#1a237e;color:#fff;padding:2rem 1rem;text-align:center}
header h1{font-size:1.5rem;margin-bottom:.5rem}
header p{opacity:.9;font-size:.9rem}
main{flex:1;max-width:1000px;margin:0 auto;padding:2rem 1rem;width:100%}
.services{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:1rem;margin-bottom:2rem}
.card{background:#fff;border-radius:8px;padding:1.5rem;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.card h3{color:#1a237e;margin-bottom:.5rem;font-size:1rem}
.card p{font-size:.9rem;color:#666;line-height:1.5}
.about{background:#fff;border-radius:8px;padding:1.5rem;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.about h2{color:#1a237e;font-size:1.1rem;margin-bottom:1rem}
.about p{line-height:1.6;font-size:.9rem;color:#444}
footer{background:#333;color:#999;text-align:center;padding:1.5rem;font-size:.8rem;margin-top:2rem}
</style>
</head>
<body>
<header>
<h1>ООО "НКТ-Консалтинг"</h1>
<p>Аудит • Бухгалтерское сопровождение • Налоговый консалтинг</p>
</header>
<main>
<div class="services">
<div class="card"><h3>Аудиторские проверки</h3><p>Обязательный и инициативный аудит бухгалтерской отчётности. Оценка налоговых рисков.</p></div>
<div class="card"><h3>Бухгалтерское обслуживание</h3><p>Полное ведение бухгалтерского и налогового учёта. Подготовка и сдача отчётности.</p></div>
<div class="card"><h3>Налоговый консалтинг</h3><p>Оптимизация налогообложения. Защита при налоговых проверках. Досудебное урегулирование.</p></div>
</div>
<div class="about">
<h2>О компании</h2>
<p>"НКТ-Консалтинг" оказывает профессиональные услуги в области аудита, бухгалтерского учёта и налогового консалтинга с 2014 года. Наши специалисты имеют аттестаты аудиторов и многолетний опыт работы с предприятиями различных отраслей.</p>
<p style="margin-top:1rem;color:#999;font-size:.85rem">Краснодарский край, г. Краснодар. Лицензия Минфина РФ № 1234567890.</p>
</div>
</main>
<footer>&copy; 2000-2026 ООО "НКТ-Консалтинг". Все права защищены.</footer>
</body>
</html>
FALLBACK
info "Fallback-страница создана (/var/www/html/index.html)"

ADMIN_PROXY_PASS=$(openssl rand -hex 12)

cat > /etc/caddy/Caddyfile << CADDY_EOF
{
    email ${EMAIL}
}

${DOMAIN}:443 {
    tls ${EMAIL}

    route {
        handle /panel/* {
            reverse_proxy 127.0.0.1:${PANEL_PORT}
        }
        handle /user/* {
            reverse_proxy 127.0.0.1:${PANEL_PORT}
        }
        handle /self/* {
            reverse_proxy 127.0.0.1:${PANEL_PORT}
        }
        handle /samples/* {
            reverse_proxy 127.0.0.1:${PANEL_PORT}
        }
        handle /static/* {
            root * /opt/proxy-panel
            file_server
        }

        forward_proxy {
            basic_auth admin ${ADMIN_PROXY_PASS}
            hide_ip
            hide_via
            probe_resistance
        }

        root * /var/www/html
        file_server
    }
}
CADDY_EOF

systemctl daemon-reload
systemctl enable --now caddy
info "Caddy установлен на порту 443 (forward_proxy + панель + fallback)"

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

AWG_INSTALLED=false

# Пытаемся установить через apt (Debian 12, Ubuntu etc.)
if apt-get install -y -qq amneziawg amneziawg-tools 2>/dev/null; then
    AWG_INSTALLED=true
else
    warn "amneziawg не найден в apt, установка из GitHub..."

    # Устанавливаем зависимости сборки
    apt-get install -y -qq linux-headers-amd64 build-essential dkms curl unzip 2>/dev/null || true

    # Скачиваем awg/awg-quick бинарники
    AWG_TOOLS_URL=$(curl -sL "https://api.github.com/repos/amnezia-vpn/amneziawg-tools/releases/latest" | python3 -c "import sys,json; print([a['browser_download_url'] for a in json.load(sys.stdin).get('assets',[]) if 'ubuntu-22.04' in a['name']][0])" 2>/dev/null)
    [ -n "$AWG_TOOLS_URL" ] && curl -sL "$AWG_TOOLS_URL" -o /tmp/awg-tools.zip && \
        unzip -oq /tmp/awg-tools.zip -d /tmp/awg-tools && \
        install -m 755 /tmp/awg-tools/ubuntu-*04-amneziawg-tools/awg /usr/local/bin/awg && \
        install -m 755 /tmp/awg-tools/ubuntu-*04-amneziawg-tools/awg-quick /usr/local/bin/awg-quick && \
        rm -rf /tmp/awg-tools* && AWG_INSTALLED=true

    # Собираем ядерный модуль amneziawg через DKMS
    if [ -d /usr/src/amneziawg-1.0.0 ]; then
        dkms build -m amneziawg -v 1.0.0 2>/dev/null && dkms install -m amneziawg -v 1.0.0 2>/dev/null || true
    else
        cd /tmp
        curl -sL "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/refs/heads/master.tar.gz" -o awg-kmod.tar.gz && \
        tar xzf awg-kmod.tar.gz && \
        cp -r amneziawg-linux-kernel-module-master/src /usr/src/amneziawg-1.0.0 && \
        dkms add -m amneziawg -v 1.0.0 2>/dev/null && \
        dkms build -m amneziawg -v 1.0.0 2>/dev/null && dkms install -m amneziawg -v 1.0.0 2>/dev/null || true
        rm -rf /tmp/awg-kmod* /tmp/amneziawg-linux-kernel-module-master* 2>/dev/null || true
    fi

    modprobe amneziawg 2>/dev/null || true
fi

if [ "$AWG_INSTALLED" = true ] && command -v awg &>/dev/null; then
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
    ip link delete awg0 2>/dev/null || true
    systemctl enable awg-quick@awg0 2>/dev/null || true
    systemctl start awg-quick@awg0 2>/dev/null || {
        ip link delete awg0 2>/dev/null || true
        systemctl start awg-quick@awg0 2>/dev/null || true
    }
    info "AmneziaWG установлен"
else
    warn "AmneziaWG не установлен"
fi

# --- 7b. Trojan-Go ---
info "=== Шаг 7b: Установка Trojan-Go ==="

TROJAN_VERSION="0.10.6"
curl -sL "https://github.com/p4gefau1t/trojan-go/releases/download/v${TROJAN_VERSION}/trojan-go-linux-amd64.zip" -o /tmp/trojan-go.zip
unzip -oq /tmp/trojan-go.zip -d /tmp/trojan-go
install -m 755 /tmp/trojan-go/trojan-go /usr/local/bin/trojan-go
mkdir -p /etc/trojan-go
rm -rf /tmp/trojan-go*

cat > /etc/trojan-go/config.json << TJ_EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 9443,
  "remote_addr": "127.0.0.1",
  "remote_port": 8080,
  "password": [],
  "ssl": {
    "cert": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
    "key": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem",
    "fallback_addr": "127.0.0.1",
    "fallback_port": 8080
  },
  "api": {
    "enabled": true,
    "api_addr": "127.0.0.1",
    "api_port": 10000
  }
}
TJ_EOF

cat > /etc/systemd/system/trojan-go.service << 'SVCEOF'
[Unit]
Description=Trojan-Go
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/trojan-go -config /etc/trojan-go/config.json
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now trojan-go
info "Trojan-Go v${TROJAN_VERSION} установлен на порту 9443"

# Caddy HTTP fallback для Trojan
TROJAN_HTTP_BLOCK="http://${DOMAIN}:8080 {
    root * /var/www/html
    file_server
}"
if ! grep -q "${DOMAIN}:8080" /etc/caddy/Caddyfile 2>/dev/null; then
    echo "" >> /etc/caddy/Caddyfile
    echo "$TROJAN_HTTP_BLOCK" >> /etc/caddy/Caddyfile
    systemctl reload caddy
    info "Caddy HTTP fallback :8080 добавлен"
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

# Патчим proxy_manager.sh под этот сервер
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
sed -i "s/SERVER_DOMAIN=\".*\"/SERVER_DOMAIN=\"$DOMAIN\"/" /root/proxy_manager.sh
sed -i "s|HY2_CONFIG=\"/etc/hysteria/config.yaml\"|HY2_CONFIG=\"/etc/hysteria/config.json\"|" /root/proxy_manager.sh
sed -i "s/systemctl restart hysteria-server/systemctl restart hysteria2/g" /root/proxy_manager.sh
sed -i "s/VLESS_HOST=\".*\"/VLESS_HOST=\"$DOMAIN\"/" /root/proxy_manager.sh
sed -i "s/VLESS_PORT=\".*\"/VLESS_PORT=\"$VLESS_PORT\"/" /root/proxy_manager.sh
sed -i "s/MIERU_IP=\".*\"/MIERU_IP=\"$SERVER_IP\"/" /root/proxy_manager.sh
sed -i "s|OLRTC_ICE=\"ws://.*:30001/ice\"|OLRTC_ICE=\"ws://$DOMAIN:30001/ice\"|" /root/proxy_manager.sh
sed -i "s|OLRTC_ROOM_URL=\".*\"|OLRTC_ROOM_URL=\"https://meet.egovm.ru/nyx-$DOMAIN\"|" /root/proxy_manager.sh
sed -i "s/TROJAN_CONFIG=\".*\"/TROJAN_CONFIG=\"\/etc\/sing-box\/config.json\"/" /root/proxy_manager.sh
sed -i "s/TROJAN_USERS_FILE=\".*\"/TROJAN_USERS_FILE=\"\/etc\/sing-box\/trojan_users.json\"/" /root/proxy_manager.sh
sed -i "s/TROJAN_PORT=\".*\"/TROJAN_PORT=\"9443\"/" /root/proxy_manager.sh
sed -i "s|TROJAN_CERT=\".*\"|TROJAN_CERT=\"/root/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.crt\"|" /root/proxy_manager.sh
sed -i "s|TROJAN_KEY=\".*\"|TROJAN_KEY=\"/root/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.key\"|" /root/proxy_manager.sh
sed -i "s/TROJAN_SERVICE=\".*\"/TROJAN_SERVICE=\"trojan-go\"/" /root/proxy_manager.sh
info "proxy_manager.sh настроен под домен $DOMAIN"

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

# Ждём создания БД и создаём admin пользователя
sleep 2
python3 -c "
import sqlite3, time
from werkzeug.security import generate_password_hash
for _ in range(10):
    try:
        db = sqlite3.connect('/opt/proxy-panel/panel.db')
        db.execute('INSERT OR IGNORE INTO users (username,password_hash,role) VALUES (?,?,?)',
                   ('admin', generate_password_hash('${PANEL_PASS}'), 'admin'))
        db.commit()
        db.close()
        break
    except:
        time.sleep(1)
" 2>/dev/null || true

# --- 9. Watchdog ---
info "=== Шаг 9: Service Watchdog ==="

cat > /usr/local/bin/service-watchdog.sh << 'WDEOF'
#!/bin/bash
SERVICES="xray caddy hysteria-server hysteria2 mita olcrtc awg-quick@awg0 trojan-go"
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
[ "$CHANGED" -eq 1 ] && chown hysteria:hysteria "$DST"/*.pem 2>/dev/null && systemctl restart hysteria2 sing-box-naive && echo "$(date) Synced cert" >> /var/log/hy2-cert-sync.log
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
echo -e "Панель: ${CYAN}https://${DOMAIN}/self/login${NC}"
echo -e "Логин:  ${CYAN}admin${NC}  Пароль: ${CYAN}${PANEL_PASS}${NC}"
echo -e "Reality PK: ${YELLOW}${REALITY_PUBLIC}${NC}"
echo -e "Short ID:   ${YELLOW}${SHORT_ID}${NC}"
echo -e "Hy2 obfs:   ${YELLOW}${OBFSC_PASS}${NC}"
echo -e "Hy2 init:   ${YELLOW}initial_user:${INIT_PASS}${NC}"
echo -e "Caddy proxy: ${CYAN}admin${NC}:${CYAN}${ADMIN_PROXY_PASS}${NC}"
echo -e "Naive proxy: ${CYAN}initial${NC}:${CYAN}${NAIVE_PASSWORD}${NC}"
echo ""
echo -e "Сервисы:"
for svc in xray caddy sing-box-naive hysteria2 mita olcrtc trojan-go panel; do
    echo -e "  $svc: ${CYAN}$(systemctl is-active $svc 2>/dev/null || echo 'n/a')${NC}"
done

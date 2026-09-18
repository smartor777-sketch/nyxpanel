#!/bin/bash
# ==============================================================================
# NYX Panel — tproxy-server (Telegram WEB Proxy) Installer
# Устанавливает tproxy-server + official MTProxy на существующий сервер NYX Panel
# Запускать от root на prod сервере (87.120.186.100)
# ==============================================================================
set -euo pipefail

RED='\033[1;91m'; GREEN='\033[1;92m'; YELLOW='\033[1;93m'; CYAN='\033[1;96m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Параметры ---
TPROXY_HOSTNAME="${TPROXY_HOSTNAME:-tg.kuban-forum.ru}"
ACME_EMAIL="${ACME_EMAIL:-furi_wave@mail.ru}"

if [ "$(id -u)" -ne 0 ]; then error "Запускать от root"; fi
if [ "$(uname -m)" != "x86_64" ]; then error "Только x86_64"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. Зависимости ---
info "=== Шаг 1: Установка зависимостей ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl nftables build-essential libssl-dev zlib1g-dev iproute2 > /dev/null 2>&1

# --- 2. Go (проверка/установка) ---
info "=== Шаг 2: Проверка Go ==="
GO_BINARY=""
if command -v go >/dev/null 2>&1; then
    go_minor="$(go env GOVERSION | sed -E 's/^go1\.([0-9]+).*/\1/')"
    if [[ "$go_minor" =~ ^[0-9]+$ ]] && [[ "$go_minor" -ge 20 ]]; then
        GO_BINARY="$(command -v go)"
        info "Go найден: $(go version)"
    fi
fi
if [ -z "$GO_BINARY" ]; then
    GO_VERSION="1.26.5"
    info "Установка Go ${GO_VERSION}..."
    cd /tmp
    curl -sL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o go.tar.gz
    tar -C /usr/local -xzf go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    rm -f go.tar.gz
    GO_BINARY="/usr/local/go/bin/go"
    info "Go ${GO_VERSION} установлен"
fi

# --- 3. Пользователи ---
info "=== Шаг 3: Создание системных пользователей ==="
if ! id tproxy >/dev/null 2>&1; then
    useradd -r -M -U -s /usr/sbin/nologin tproxy
    info "Пользователь tproxy создан"
else
    info "Пользователь tproxy уже существует"
fi
if ! id mtproxy >/dev/null 2>&1; then
    useradd -r -M -U -s /usr/sbin/nologin mtproxy
    info "Пользователь mtproxy создан"
else
    info "Пользователь mtproxy уже существует"
fi

# --- 4. Сборка tproxy-server ---
info "=== Шаг 4: Сборка tproxy-server ==="
if [ -f /usr/local/bin/tproxy-server ]; then
    info "tproxy-server уже установлен, пропускаем сборку"
else
    cd /tmp
    rm -rf tproxy-server-build
    git clone --depth 1 https://github.com/telegramdesktop/tproxy-server.git tproxy-server-build
    cd tproxy-server-build
    "$GO_BINARY" test ./...
    "$GO_BINARY" build -trimpath -ldflags='-s -w' -o /usr/local/bin/tproxy-server ./cmd/tproxy-server
    chown root:root /usr/local/bin/tproxy-server
    chmod 0755 /usr/local/bin/tproxy-server
    rm -rf /tmp/tproxy-server-build
    info "tproxy-server собран и установлен"
fi

# --- 5. Сборка Official MTProxy ---
info "=== Шаг 5: Сборка Official MTProxy ==="
MTPROXY_COMMIT="f36d8af769ffaeac36978d38c2c0f6d1104c2137"
if [ -x /opt/MTProxy/objs/bin/mtproto-proxy ] && [ -f /opt/MTProxy/.tproxy-commit ] && grep -Fxq "$MTPROXY_COMMIT" /opt/MTProxy/.tproxy-commit 2>/dev/null; then
    info "MTProxy уже установлен (коммит $MTPROXY_COMMIT), пропускаем"
else
    cd /tmp
    rm -rf mtproxy-build
    mkdir -p mtproxy-build
    curl -sL "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" -o mtproxy.tar.gz
    tar xzf mtproxy.tar.gz -C mtproxy-build --strip-components=1
    chown -R mtproxy:mtproxy mtproxy-build
    runuser -u mtproxy -- make -C mtproxy-build -j"$(nproc)"
    if [ ! -x mtproxy-build/objs/bin/mtproto-proxy ]; then
        error "Сборка MTProxy не удалась"
    fi
    mkdir -p /opt/MTProxy
    chown -R root:root mtproxy-build
    mv mtproxy-build/* /opt/MTProxy/
    echo "$MTPROXY_COMMIT" > /opt/MTProxy/.tproxy-commit
    rm -rf /tmp/mtproxy-build mtproxy.tar.gz
    info "MTProxy собран и установлен"
fi

# --- 6. Скачивание MTProxy секрета и конфига ---
info "=== Шаг 6: Скачивание MTProxy секрета и маршрутов ==="
install -d -o root -g mtproxy -m 0750 /etc/mtproxy
curl -s https://core.telegram.org/getProxySecret -o /etc/mtproxy/proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o /etc/mtproxy/proxy-multi.conf
chown root:mtproxy /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf
chmod 0640 /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf
info "MTProxy secret и config скачаны"

# --- 7. Конфигурация ---
info "=== Шаг 7: Установка конфигурации ==="
install -d -o root -g tproxy -m 0750 /etc/tproxy-server

# Secret для MTProxy
TPROXY_SECRET=$(openssl rand -hex 16)
info "Сгенерирован secret: $TPROXY_SECRET"

# Token key (для аутентификации сессий)
if [ ! -f /etc/tproxy-server/token.key ]; then
    head -c 32 /dev/urandom > /etc/tproxy-server/token.key
    chown tproxy:tproxy /etc/tproxy-server/token.key
    chmod 0400 /etc/tproxy-server/token.key
    info "Token key создан"
fi

# config.json
cat > /etc/tproxy-server/config.json << CONFEOF
{
  "public_hostname": "$TPROXY_HOSTNAME",
  "base_path": "",
  "listen": "127.0.0.1:8090",
  "admin_listen": "127.0.0.1:8081",
  "public_dir": "/srv/tproxy-site",
  "static_routes": "exact",
  "token_key_file": "/etc/tproxy-server/token.key",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json",
  "enable_pprof": false,
  "limits": {
    "max_sessions_global": 128,
    "max_streams_global": 4096,
    "max_backend_dials_in_flight": 256,
    "new_sessions_per_minute": 600,
    "new_sessions_burst": 128,
    "new_streams_per_minute": 6000,
    "new_streams_burst": 512,
    "max_bootstraps_global": 512,
    "new_bootstraps_per_minute": 1200,
    "new_bootstraps_burst": 256,
    "max_profiles": 32
  },
  "timeouts": {
    "backend_dial": "5s",
    "long_poll": "25s",
    "reconnect_grace": "2m",
    "bootstrap_lifetime": "2m",
    "read_header": "10s",
    "idle": "75s",
    "shutdown": "15s"
  }
}
CONFEOF
chown root:tproxy /etc/tproxy-server/config.json
chmod 0640 /etc/tproxy-server/config.json

# profiles.json
cat > /etc/tproxy-server/profiles.json << PROFEOF
{"profiles":[{"name":"default","secret":"$TPROXY_SECRET","backend":"127.0.0.1:2398","carrier_mode":"https"}]}
PROFEOF
chown root:tproxy /etc/tproxy-server/profiles.json
chmod 0400 /etc/tproxy-server/profiles.json

# mtproxy.env
# NAT detection
LOCAL_ADDR=$(ip -4 route get 149.154.175.50 2>/dev/null | sed -n 's/.*src \([0-9.]\+\).*/\1/p' | head -n1)
PUBLIC_ADDR=$(curl -s --max-time 15 https://api.ipify.org 2>/dev/null || curl -s --max-time 15 https://ifconfig.co/ip 2>/dev/null || echo "")
NAT_ARGS=""
if [ -n "$LOCAL_ADDR" ] && [ -n "$PUBLIC_ADDR" ] && [ "$LOCAL_ADDR" != "$PUBLIC_ADDR" ]; then
    NAT_ARGS="--nat-info $LOCAL_ADDR:$PUBLIC_ADDR"
    info "NAT detected: $LOCAL_ADDR -> $PUBLIC_ADDR"
fi

cat > /etc/mtproxy/mtproxy.env << ENVFEOF
MTPROXY_SECRET=$TPROXY_SECRET
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
MTPROXY_NAT_ARGS=$NAT_ARGS
ENVFEOF
chown root:mtproxy /etc/mtproxy/mtproxy.env
chmod 0640 /etc/mtproxy/mtproxy.env

# Firewall (nftables)
install -m 0644 "$SCRIPT_DIR/firewall.nft" /etc/tproxy-server/firewall.nft

# Fallback site
install -d -m 0755 /srv/tproxy-site
if [ ! -f /srv/tproxy-site/index.html ]; then
    install -m 0644 "$SCRIPT_DIR/index.html" /srv/tproxy-site/index.html
    info "Fallback сайт создан"
else
    info "Fallback сайт уже существует"
fi

# --- 8. Systemd-сервисы ---
info "=== Шаг 8: Установка systemd-сервисов ==="
install -m 0644 "$SCRIPT_DIR/tproxy-firewall.service" /etc/systemd/system/tproxy-firewall.service
install -m 0644 "$SCRIPT_DIR/mtproxy.service" /etc/systemd/system/mtproxy.service
install -m 0644 "$SCRIPT_DIR/tproxy-server.service" /etc/systemd/system/tproxy-server.service

# Refresh timer (обновление MTProxy конфига раз в сутки)
cat > /etc/systemd/system/refresh-mtproxy-config.service << 'REFRESHEOF'
[Unit]
Description=Refresh MTProxy config from Telegram
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -sf https://core.telegram.org/getProxySecret -o /etc/mtproxy/proxy-secret.new && curl -sf https://core.telegram.org/getProxyConfig -o /etc/mtproxy/proxy-multi.conf.new && cmp -s /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-secret.new || mv /etc/mtproxy/proxy-secret.new /etc/mtproxy/proxy-secret; cmp -s /etc/mtproxy/proxy-multi.conf /etc/mtproxy/proxy-multi.conf.new && rm -f /etc/mtproxy/proxy-multi.conf.new /etc/mtproxy/proxy-secret.new || { mv /etc/mtproxy/proxy-multi.conf.new /etc/mtproxy/proxy-multi.conf; systemctl restart mtproxy; } && rm -f /etc/mtproxy/proxy-secret.new /etc/mtproxy/proxy-multi.conf.new'
User=root
REFRESHEOF

cat > /etc/systemd/system/refresh-mtproxy-config.timer << 'TIMEREOF'
[Unit]
Description=Refresh MTProxy config daily

[Timer]
OnBootSec=5min
OnUnitActiveSec=24h

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload

# --- 9. Валидация ---
info "=== Шаг 9: Валидация конфигурации ==="
/usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json -check 2>/dev/null || \
/usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json -check
info "tproxy-server config OK"

# --- 10. Запуск сервисов ---
info "=== Шаг 10: Запуск сервисов ==="
systemctl enable --now tproxy-firewall.service
systemctl enable --now mtproxy.service
systemctl enable --now tproxy-server.service
systemctl enable --now refresh-mtproxy-config.timer

# --- 11. Обновление Caddyfile ---
info "=== Шаг 11: Обновление Caddyfile ==="
CADDYFILE="/etc/caddy/Caddyfile"
if ! grep -q "tg.kuban-forum.ru" "$CADDYFILE" 2>/dev/null; then
    cp "$CADDYFILE" "${CADDYFILE}.before-tproxy.$(date +%Y%m%d%H%M%S)"
    cat >> "$CADDYFILE" << 'CADDYEOF'

tg.kuban-forum.ru {
    encode zstd gzip
    header {
        -Via
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }
    reverse_proxy 127.0.0.1:8090 {
        transport http {
            response_header_timeout 40s
        }
    }
    handle_errors {
        header {
            Cache-Control "no-store"
            Strict-Transport-Security "max-age=31536000; includeSubDomains"
        }
        respond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}
    }
}
CADDYEOF
    info "Caddyfile обновлён (добавлен блок tg.kuban-forum.ru)"
else
    info "Caddyfile уже содержит блок tg.kuban-forum.ru"
fi

# Перезапуск Caddy
systemctl reload caddy 2>/dev/null || systemctl restart caddy

# --- 12. Проверка ---
info "=== Шаг 12: Проверка ==="
sleep 2

RELAY_READY=""
for ((attempt=0; attempt!=20; attempt++)); do
    if curl --fail --silent --output /dev/null http://127.0.0.1:8081/readyz 2>/dev/null; then
        RELAY_READY=1
        break
    fi
    sleep 1
done

if [ -z "$RELAY_READY" ]; then
    warn "tproxy-server не стал ready (проверьте journalctl -u tproxy-server)"
else
    info "tproxy-server ready"
fi

# --- Итог ---
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Telegram WEB Proxy — Установка завершена!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "Hostname:     ${CYAN}https://${TPROXY_HOSTNAME}${NC}"
echo -e "MTProxy sec:  ${YELLOW}${TPROXY_SECRET}${NC}"
echo ""
echo -e "Ссылка для клиентов:"
CLIENT_ADDR="$TPROXY_HOSTNAME"
echo -e "  ${CYAN}https://t.me/webproxy?server=${CLIENT_ADDR}&secret=${TPROXY_SECRET}${NC}"
echo ""
echo -e "Сервисы:"
for svc in tproxy-firewall mtproxy tproxy-server; do
    echo -e "  $svc: ${CYAN}$(systemctl is-active $svc 2>/dev/null || echo 'n/a')${NC}"
done
echo ""
echo -e "Проверка:"
echo -e "  curl --fail https://${TPROXY_HOSTNAME}/"
echo -e "  curl --fail http://127.0.0.1:8081/readyz"
echo -e "  systemctl --no-pager --full status caddy mtproxy tproxy-server"

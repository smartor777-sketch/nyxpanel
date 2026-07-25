#!/usr/bin/env bash
set -e
INSTALL_DIR="/opt/proxy-panel"

echo "==> Installing panel to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/templates" "$INSTALL_DIR/static"
cp "$(dirname "$0")/app.py" "$INSTALL_DIR/app.py"
cp "$(dirname "$0")/templates/index.html" "$INSTALL_DIR/templates/index.html"

echo "==> Installing Flask"
pip3 install flask --break-system-packages 2>/dev/null || pip3 install flask

echo "==> Creating panel.service"
cat > /etc/systemd/system/panel.service << 'SVC'
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
SVC

systemctl daemon-reload
systemctl enable --now panel.service

echo "==> Panel running on http://127.0.0.1:5000"

if grep -q "panel.<YOUR_DOMAIN>" /etc/caddy/Caddyfile 2>/dev/null; then
    echo "==> Panel already in Caddyfile"
else
    echo "==> Adding panel to Caddyfile"
    cat >> /etc/caddy/Caddyfile << 'CADDY'

# Proxy Panel
panel.<YOUR_DOMAIN>:8443 {
    basicauth {
        admin $2a$14$CHANGEME
    }
    reverse_proxy 127.0.0.1:5000
}
CADDY
    systemctl reload caddy
fi

echo ""
echo "============================================"
echo "  Panel installed!"
echo "  URL: https://panel.<YOUR_DOMAIN>:8443"
echo ""
echo "  Set password:"
echo "    caddy hash-password --plaintext 'yourpass'"
echo "    nano /etc/caddy/Caddyfile  # replace CHANGEME"
echo "    systemctl reload caddy"
echo "============================================"

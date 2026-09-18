#!/bin/bash
# Deploy Telegram Web Proxy Bot to production server
set -e

PANEL_DIR="/opt/proxy-panel"
SERVICE_NAME="tg-proxy-bot"

echo "=== Deploying Telegram Web Proxy Bot ==="

# Check bot.env
if [ ! -f /etc/tproxy-server/bot.env ]; then
    echo "Creating bot.env from example..."
    cp /etc/tproxy-server/bot.env.example /etc/tproxy-server/bot.env 2>/dev/null || true
    echo "⚠️  Edit /etc/tproxy-server/bot.env with your BOT_TOKEN and ADMINS"
fi

# Copy bot file
echo "Copying bot script..."
cp tg_proxy_bot.py "$PANEL_DIR/tg_proxy_bot.py"

# Copy service file
echo "Installing systemd service..."
cp tg-proxy-bot.service /etc/systemd/system/
systemctl daemon-reload

# Enable and start
echo "Enabling service..."
systemctl enable "$SERVICE_NAME"
echo "Restarting service..."
systemctl restart "$SERVICE_NAME"

echo ""
echo "=== Done ==="
echo "Check status: systemctl status $SERVICE_NAME"
echo "View logs:    journalctl -u $SERVICE_NAME -f"
echo ""
echo "⚠️  Make sure /etc/tproxy-server/bot.env has correct TG_PROXY_BOT_TOKEN"

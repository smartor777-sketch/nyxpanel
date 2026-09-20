#!/bin/bash
set -e

# Generate shared secrets
SHARED_HTTPS=$(openssl rand -hex 16)
SHARED_HTTPS_LANES=$(openssl rand -hex 16)
SHARED_WS=$(openssl rand -hex 16)
SHARED_WS_LANES=$(openssl rand -hex 16)

echo "HTTPS: $SHARED_HTTPS"
echo "HTTPS-LANES: $SHARED_HTTPS_LANES"
echo "WEBSOCKET: $SHARED_WS"
echo "WEBSOCKET-LANES: $SHARED_WS_LANES"

# Create env files
for mode_port in "https:2501:$SHARED_HTTPS" "https-lanes:2502:$SHARED_HTTPS_LANES" "websocket:2503:$SHARED_WS" "websocket-lanes:2504:$SHARED_WS_LANES"; do
  IFS=: read mode port secret <<< "$mode_port"
  cat > "/etc/mtproxy/mtproxy-shared-${mode}.env" << EOF
MTPROXY_SECRET=${secret}
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
EOF
  echo "Created env: shared-${mode} port=${port}"
done

# Create launcher scripts
for mode_port in "https:2501" "https-lanes:2502" "websocket:2503" "websocket-lanes:2504"; do
  IFS=: read mode port <<< "$mode_port"
  proxy_port=$((port + 1000))
  cat > "/usr/local/bin/mtproxy-shared-${mode}.sh" << EOF
#!/bin/bash
set -a
source /etc/mtproxy/mtproxy-shared-${mode}.env
set +a
exec /opt/MTProxy/objs/bin/mtproto-proxy -u mtproxy -p ${proxy_port} -H ${port} -S \$MTPROXY_SECRET --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M \$MTPROXY_WORKERS -C \$MTPROXY_MAX_CONNECTIONS
EOF
  chmod 755 "/usr/local/bin/mtproxy-shared-${mode}.sh"
  echo "Created script: shared-${mode} tcp=${proxy_port} http=${port}"
done

# Create systemd services
for mode_port in "https:2501" "https-lanes:2502" "websocket:2503" "websocket-lanes:2504"; do
  IFS=: read mode port <<< "$mode_port"
  cat > "/etc/systemd/system/mtproxy-shared-${mode}.service" << EOF
[Unit]
Description=MTProxy shared backend (${mode})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtproxy
Group=mtproxy
WorkingDirectory=/opt/MTProxy
ExecStart=/usr/local/bin/mtproxy-shared-${mode}.sh
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectProc=invisible
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF
  echo "Created service: mtproxy-shared-${mode}.service"
done

# Reload and start
systemctl daemon-reload
for mode in https https-lanes websocket websocket-lanes; do
  systemctl enable "mtproxy-shared-${mode}"
  systemctl start "mtproxy-shared-${mode}"
  echo "Started: mtproxy-shared-${mode}"
done

echo "=== STATUS ==="
systemctl is-active mtproxy-shared-https mtproxy-shared-https-lanes mtproxy-shared-websocket mtproxy-shared-websocket-lanes
echo "=== PORTS ==="
ss -tlnp | grep "mtproxy-shared\|2501\|2502\|2503\|2504\|3501\|3502\|3503\|3504"

# Save secrets to a file for the panel to read
cat > /etc/mtproxy/shared-secrets.json << EOF
{
  "https": "$SHARED_HTTPS",
  "https-lanes": "$SHARED_HTTPS_LANES",
  "websocket": "$SHARED_WS",
  "websocket-lanes": "$SHARED_WS_LANES"
}
EOF
echo "Secrets saved to /etc/mtproxy/shared-secrets.json"

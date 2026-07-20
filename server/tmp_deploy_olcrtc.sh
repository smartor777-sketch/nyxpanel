#!/bin/bash
set -e

# 1. Copy users.json
cp /tmp/users.json /etc/olcrtc/users.json
chmod 600 /etc/olcrtc/users.json

# 2. Update server config to add auth.users_file
if ! grep -q 'users_file' /root/.config/olcrtc/server.yaml; then
    sed -i '/^auth:/a\  users_file: /etc/olcrtc/users.json' /root/.config/olcrtc/server.yaml
fi
echo "=== Updated server config ==="
cat /root/.config/olcrtc/server.yaml

# 3. Install new binary
cp /root/pj/olcrtc/olcrtc /root/pj/olcrtc/build/olcrtc-linux-amd64
echo "=== Binary installed ==="

# 4. Restart service
systemctl restart olcrtc
sleep 2
systemctl is-active olcrtc
echo "=== Service restarted ==="

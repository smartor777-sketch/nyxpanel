#!/bin/bash
set -e
# Remove admin, add user01 with temporary password in one atomic operation
jq 'del(.auth.userpass.admin) | .auth.userpass.user01 = "<temp_katya>"' /etc/hysteria/config.yaml > /tmp/hy2_config.tmp
mv /tmp/hy2_config.tmp /etc/hysteria/config.yaml
systemctl restart hysteria-server
sleep 1
systemctl is-active hysteria-server
echo "=== auth section ==="
jq '.auth' /etc/hysteria/config.yaml

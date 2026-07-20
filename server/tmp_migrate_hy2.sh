#!/bin/bash
set -e
jq '.auth.type = "userpass" | .auth.userpass = {} | del(.auth.password, .users)' /etc/hysteria/config.yaml > /tmp/config.tmp
mv /tmp/config.tmp /etc/hysteria/config.yaml
echo "=== updated config ==="
cat /etc/hysteria/config.yaml

#!/bin/bash
set -e
jq '.auth.userpass.admin = "temp_pass_2024"' /etc/hysteria/config.yaml > /tmp/config.tmp
mv /tmp/config.tmp /etc/hysteria/config.yaml
systemctl restart hysteria-server
sleep 2
systemctl is-active hysteria-server

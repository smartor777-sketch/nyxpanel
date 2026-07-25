#!/bin/bash
set -e

echo "=== NYX Panel Full Uninstall ==="

# Остановка и удаление сервисов
for svc in panel xray caddy hysteria2 mita olcrtc olcrtc-users olcrtc-users-serve sync-hy2-cert; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "Останавливаю $svc..."
        systemctl stop "$svc" 2>/dev/null || true
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        systemctl disable "$svc" 2>/dev/null || true
    fi
    rm -f "/etc/systemd/system/${svc}.service"
    rm -f "/etc/systemd/system/${svc}.service.d/*.conf"
done

# AmneziaWG
if systemctl is-active --quiet "awg-quick@awg0" 2>/dev/null; then
    systemctl stop "awg-quick@awg0" 2>/dev/null || true
fi
systemctl disable "awg-quick@awg0" 2>/dev/null || true

# Watchdog cron
crontab -l 2>/dev/null | grep -v service-watchdog | crontab - 2>/dev/null || true

# Синхронизация cert
systemctl disable sync-hy2-cert.timer 2>/dev/null || true
systemctl stop sync-hy2-cert.timer 2>/dev/null || true

systemctl daemon-reload

echo "=== Удаляю бинарники и файлы ==="

# xray
rm -f /usr/local/bin/xray
rm -rf /usr/local/share/xray
rm -rf /etc/xray

# caddy
rm -f /usr/bin/caddy
rm -rf /var/lib/caddy
rm -rf /etc/caddy
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
rm -f /etc/apt/sources.list.d/caddy-stable.list

# hysteria2
rm -f /usr/local/bin/hysteria2
rm -rf /etc/hysteria2
rm -f /etc/systemd/system/sync-hy2-cert.service
rm -f /etc/systemd/system/sync-hy2-cert.timer

# mita (Mieru)
rm -f /usr/bin/mita
rm -rf /var/run/mita
rm -rf /var/lib/mita

# olcrtc
rm -f /root/olcrtc
rm -f /usr/local/bin/olcrtc

# panel
rm -rf /opt/proxy-panel
rm -f /root/proxy_manager.sh

# AmneziaWG
rm -rf /etc/amnezia
apt-get remove -y amneziawg-tools 2>/dev/null || true

# watchdog
rm -f /usr/local/bin/service-watchdog.sh
rm -rf /var/log/service-watchdog.log

# LE cert для старого домена
rm -rf /etc/letsencrypt/live/<YOUR_DOMAIN>

# Таймеры
rm -f /etc/systemd/system/sync-hy2-cert.*

# GeoIP/GeoSite файлы
rm -f /usr/local/share/xray/geoip.dat /usr/local/share/xray/geosite.dat

# DNS записи (если есть)
rm -f /etc/hosts.d/nyx*

# UFW — сбросить правила (но не удалять сам UFW)
ufw --force reset 2>/dev/null || true
ufw default deny incoming 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true
ufw allow 22/tcp 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw allow 4433/tcp 2>/dev/null || true
ufw allow 8443/tcp 2>/dev/null || true
ufw allow 30000/udp 2>/dev/null || true
ufw allow 39743/udp 2>/dev/null || true
ufw allow 444:448/udp 2>/dev/null || true
ufw --force enable 2>/dev/null || true

echo "=== Проверяю остатки ==="
echo "Bинарники:"
ls /usr/local/bin/xray /usr/bin/xray /usr/bin/caddy /usr/local/bin/caddy /usr/bin/mita /root/olcrtc /usr/local/bin/olcrtc 2>&1 || true
echo "Конфиги:"
ls /etc/xray /etc/caddy /etc/hysteria2 /etc/amnezia 2>&1 || true
echo "Панель:"
ls /opt/proxy-panel 2>&1 || true
echo "Сервисы:"
systemctl list-unit-files --type=service | grep -E "xray|caddy|hysteria|mita|olcrtc|panel|awg" || echo "Нет сервисов"

echo ""
echo "=== Деинсталляция завершена ==="

import subprocess

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'
plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

cmds = [
    'systemctl stop xray caddy hysteria2 mita panel olcrtc 2>/dev/null || true',
    'systemctl disable xray caddy hysteria2 mita panel olcrtc 2>/dev/null || true',
    'rm -f /etc/systemd/system/xray.service /etc/systemd/system/panel.service /etc/systemd/system/olcrtc.service /etc/systemd/system/olcrtc-users.service',
    'rm -f /lib/systemd/system/caddy* /etc/systemd/system/caddy*',
    'rm -f /etc/systemd/system/hysteria2.service /etc/systemd/system/sync-hy2-cert.*',
    'rm -f /etc/systemd/system/mita.service /usr/lib/systemd/system/mita.service',
    'rm -f /usr/local/bin/xray /usr/local/bin/hysteria2 /root/olcrtc',
    'dpkg --purge caddy mita 2>/dev/null || true',
    'rm -rf /etc/caddy /etc/hysteria2 /etc/xray /etc/amnezia /opt/proxy-panel /root/proxy_manager.sh',
    'rm -rf /var/log/xray /var/log/hysteria /var/log/olcrtc /var/run/mita /usr/local/etc/xray /var/lib/mita',
    'rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list',
    'crontab -l 2>/dev/null | grep -v service-watchdog | crontab - 2>/dev/null || true',
    'rm -f /usr/local/bin/service-watchdog.sh',
    'rm -f /root/install.sh /root/install_out.log /root/install_err.log /root/debug*',
    'systemctl daemon-reload',
    'echo "CLEAN_DONE"',
]

for cmd in cmds:
    r = subprocess.run(plink + [cmd], capture_output=True, text=True, timeout=60)
    if 'CLEAN_DONE' in r.stdout:
        print(r.stdout)

print('=== Verification ===')
r = subprocess.run(plink + ['ls /usr/local/bin/xray /usr/bin/caddy /usr/local/bin/hysteria2 /opt/proxy-panel/app.py /etc/caddy/Caddyfile 2>&1 || echo "OK - nothing found"'], capture_output=True, text=True, timeout=15)
print(r.stdout)

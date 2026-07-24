import subprocess

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'
plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

cmds = [
    'systemctl disable caddy.service 2>/dev/null; systemctl disable caddy-api.service 2>/dev/null; rm -f /lib/systemd/system/caddy.service /lib/systemd/system/caddy-api.service /etc/systemd/system/caddy*; systemctl daemon-reload; systemctl reset-failed',
    'systemctl list-unit-files --type=service | grep -E "xray|caddy|hysteria|mita|olcrtc|panel|awg" || echo "ЧИСТО"',
]

for cmd in cmds:
    r = subprocess.run(plink + [cmd], capture_output=True, text=True, timeout=30)
    print(r.stdout.strip())

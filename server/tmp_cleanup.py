import subprocess

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'

plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

cmds = [
    'dpkg --purge mita 2>/dev/null; apt-get remove -y --purge mita 2>/dev/null || true',
    'rm -f /usr/bin/mita /usr/lib/systemd/system/mita.service /etc/systemd/system/mita.service',
    'rm -f /etc/systemd/system/caddy.service /etc/systemd/system/caddy-api.service',
    'rm -rf /var/lib/dpkg/info/mita.*',
    'systemctl daemon-reload',
    'apt-get autoremove -y 2>/dev/null || true',
    'systemctl list-unit-files --type=service | grep -E "xray|caddy|hysteria|mita|olcrtc|panel|awg"',
]

for cmd in cmds:
    r = subprocess.run(plink + [cmd], capture_output=True, text=True, timeout=60)
    if r.stdout.strip():
        print(r.stdout.strip())
    if r.returncode != 0 and r.stderr:
        print(f'  ERR: {r.stderr.strip()[:200]}')

import subprocess, base64

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'
plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

env_vars = 'DOMAIN=test.kuban-forum.ru PANEL_PASS=testadmin123 EMAIL=furi_wave@mail.ru'

# Run install.sh without set -e to see all errors
r = subprocess.run(plink + [f'{env_vars} bash -x /root/install.sh 2>/root/install_err.log'], capture_output=True, text=True, timeout=600)
print('stdout last 5000 chars:')
print(r.stdout[-5000:] if len(r.stdout) > 5000 else r.stdout)
if r.returncode != 0:
    print('EXIT CODE:', r.returncode)
    # Check error log
    r2 = subprocess.run(plink + ['cat /root/install_err.log 2>/dev/null | head -100'], capture_output=True, text=True, timeout=15)
    if r2.stdout.strip():
        print('STDERR from file:')
        print(r2.stdout[:3000])

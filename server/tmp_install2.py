import subprocess, base64

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'
plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

# Run with more verbose output and redirect to a log file
env_vars = 'DOMAIN=test.example.com PANEL_PASS=<пароль_panel_test> EMAIL=admin@example.com'
r = subprocess.run(plink + [f'{env_vars} bash /root/install.sh 2>&1 | tee /root/install.log'], capture_output=True, text=True, timeout=600)
print(r.stdout)
if r.returncode != 0:
    print('EXIT CODE:', r.returncode)

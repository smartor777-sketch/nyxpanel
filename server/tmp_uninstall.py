import subprocess, base64, sys

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'

with open(r'C:\Users\Alex\nyxpanel\server\uninstall.sh', 'r', encoding='utf-8') as f:
    script = f.read()

encoded = base64.b64encode(script.encode('utf-8')).decode('ascii')

plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

# Upload
r = subprocess.run(plink + [f'echo {encoded} | base64 -d > /tmp/uninstall.sh && chmod +x /tmp/uninstall.sh'], capture_output=True, text=True, timeout=30)
print('Upload:', 'OK' if r.returncode == 0 else f'rc={r.returncode}')
if r.stderr: print(r.stderr[:300])

# Run
r2 = subprocess.run(plink + ['bash /tmp/uninstall.sh'], capture_output=True, text=True, timeout=120)
print(r2.stdout)
if r2.returncode != 0:
    print('STDERR:', r2.stderr[-1000:] if r2.stderr else 'none')

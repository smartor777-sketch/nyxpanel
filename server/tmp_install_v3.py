import subprocess, base64

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'

with open(r'C:\Users\Alex\nyxpanel\server\install.sh', 'r', encoding='utf-8') as f:
    script = f.read()

encoded = base64.b64encode(script.encode('utf-8')).decode('ascii')

plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

r = subprocess.run(plink + [f'echo {encoded} | base64 -d > /root/install.sh && chmod +x /root/install.sh'], capture_output=True, text=True, timeout=30)
print('Upload:', 'OK' if r.returncode == 0 else f'rc={r.returncode}')

# Run install.sh - write both stdout and stderr to a log file on the server
r = subprocess.run(plink + ['DOMAIN=test.kuban-forum.ru PANEL_PASS=testadmin123 EMAIL=furi_wave@mail.ru bash /root/install.sh 2>/root/install_err.log'], capture_output=True, text=True, timeout=600)
print(r.stdout[-4000:] if len(r.stdout) > 4000 else r.stdout)
if r.returncode != 0:
    print('EXIT CODE:', r.returncode)
    # Check error log
    r2 = subprocess.run(plink + ['cat /root/install_err.log 2>/dev/null | head -50'], capture_output=True, text=True, timeout=15)
    if r2.stdout.strip():
        print('=== STDERR ===')
        print(r2.stdout)

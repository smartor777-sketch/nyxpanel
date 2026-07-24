import subprocess, base64

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'

with open(r'C:\Users\Alex\nyxpanel\server\install.sh', 'r', encoding='utf-8') as f:
    script = f.read()

encoded = base64.b64encode(script.encode('utf-8')).decode('ascii')

plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

# Upload fresh copy
r = subprocess.run(plink + [f'echo {encoded} | base64 -d > /root/install.sh && chmod +x /root/install.sh'], capture_output=True, text=True, timeout=30)
print('Upload:', 'OK' if r.returncode == 0 else f'rc={r.returncode}')

# Run with nohup so it doesn't hang on plink disconnect
r = subprocess.run(plink + ['DOMAIN=test.kuban-forum.ru PANEL_PASS=testadmin123 EMAIL=furi_wave@mail.ru nohup bash /root/install.sh > /root/install_out.log 2>&1 &'], capture_output=True, text=True, timeout=30)
print('Launch:', 'OK' if r.returncode == 0 else f'rc={r.returncode}')

import time
for i in range(24):  # 2 minutes of checking
    time.sleep(5)
    r2 = subprocess.run(plink + ['cat /root/install_out.log 2>/dev/null | wc -l'], capture_output=True, text=True, timeout=10)
    lines = r2.stdout.strip()
    r3 = subprocess.run(plink + ['pgrep -f "install.sh" 2>/dev/null || echo "done"'], capture_output=True, text=True, timeout=10)
    status = r3.stdout.strip()
    r4 = subprocess.run(plink + ['tail -10 /root/install_out.log 2>/dev/null'], capture_output=True, text=True, timeout=10)
    tail = r4.stdout.strip() or '(empty)'
    print(f'[{i*5}s] lines={lines} running={status} last={tail[:200]}')
    if 'done' in status:
        break

import subprocess, base64, time

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'
plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

with open(r'C:\Users\Alex\nyxpanel\server\install.sh', 'r', encoding='utf-8') as f:
    script = f.read()
encoded = base64.b64encode(script.encode('utf-8')).decode('ascii')

r = subprocess.run(plink + [f'echo {encoded} | base64 -d > /root/install.sh && chmod +x /root/install.sh'], capture_output=True, text=True, timeout=30)
print('Upload:', 'OK' if r.returncode == 0 else f'rc={r.returncode}')

# Run in background with output to log
r = subprocess.run(plink + ['nohup bash -c "DOMAIN=test.kuban-forum.ru PANEL_PASS=testadmin123 EMAIL=furi_wave@mail.ru bash /root/install.sh" > /root/install.log 2>&1 &'], capture_output=True, text=True, timeout=30)
print('Launch:', 'OK' if r.returncode == 0 else f'rc={r.returncode}')

# Monitor progress
for i in range(60):
    time.sleep(10)
    r = subprocess.run(plink + ['tail -3 /root/install.log 2>/dev/null'], capture_output=True, text=True, timeout=15)
    tail = r.stdout.strip() or '(waiting...)'
    r2 = subprocess.run(plink + ['pgrep -f "install.sh" 2>/dev/null || echo done'], capture_output=True, text=True, timeout=10)
    running = r2.stdout.strip()
    print(f'[{i*10}s] {tail[:100]}')
    if 'done' in running:
        break
    if 'error' in running.lower():
        break

print('=== Final ===')
r = subprocess.run(plink + ['cat /root/install.log 2>/dev/null'], capture_output=True, text=True, timeout=30)
out = r.stdout
print(out[-3000:] if len(out) > 3000 else out)
print('EXIT:', 'running' if 'install.sh' in running else 'done')

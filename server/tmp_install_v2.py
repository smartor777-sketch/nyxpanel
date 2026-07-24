import subprocess, base64

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'

with open(r'C:\Users\Alex\nyxpanel\server\install.sh', 'r', encoding='utf-8') as f:
    script = f.read()

encoded = base64.b64encode(script.encode('utf-8')).decode('ascii')

plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

# Upload fixed install.sh
r = subprocess.run(plink + [f'echo {encoded} | base64 -d > /root/install.sh && chmod +x /root/install.sh'], capture_output=True, text=True, timeout=30)
print('Upload:', 'OK' if r.returncode == 0 else f'rc={r.returncode}')

# Run install.sh
env_cmd = 'DOMAIN=test.kuban-forum.ru PANEL_PASS=testadmin123 EMAIL=furi_wave@mail.ru'
r = subprocess.run(plink + [f'{env_cmd} bash /root/install.sh 2>&1'], capture_output=True, text=True, timeout=600)
out = r.stdout
print(out[-5000:] if len(out) > 5000 else out)
if r.returncode != 0:
    print('EXIT CODE:', r.returncode)

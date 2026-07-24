import subprocess, base64

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'

with open(r'C:\Users\Alex\nyxpanel\server\install.sh', 'r', encoding='utf-8') as f:
    script = f.read()

encoded = base64.b64encode(script.encode('utf-8')).decode('ascii')

plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

# Upload install.sh
r = subprocess.run(plink + [f'echo {encoded} | base64 -d > /root/install.sh && chmod +x /root/install.sh'], capture_output=True, text=True, timeout=30)
print('Upload install.sh:', 'OK' if r.returncode == 0 else f'rc={r.returncode}')

# Run install.sh with env vars
env_vars = 'DOMAIN=test.kuban-forum.ru PANEL_PASS=testadmin123 EMAIL=furi_wave@mail.ru'
r = subprocess.run(plink + [f'{env_vars} bash /root/install.sh'], capture_output=True, text=True, timeout=600)
out = r.stdout
# Print the end (most important part)
print(out[-4000:] if len(out) > 4000 else out)
if r.returncode != 0:
    print('EXIT CODE:', r.returncode)
    if r.stderr: print('STDERR:', (r.stderr[-2000:] if len(r.stderr) > 2000 else r.stderr))

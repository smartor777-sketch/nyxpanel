import subprocess, base64

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'
plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

# Read the LATEST install.sh from github
import urllib.request
r = urllib.request.urlopen('https://raw.githubusercontent.com/smartor777-sketch/nyxpanel/master/server/install.sh')
script = r.read().decode('utf-8')

encoded = base64.b64encode(script.encode('utf-8')).decode('ascii')

# Upload
subprocess.run(plink + [f'echo {encoded} | base64 -d > /root/install.sh && chmod +x /root/install.sh'], capture_output=True, text=True, timeout=30)
print('Upload done')

# Run with output to file, but DO NOT redirect stderr to same file (keep stderr visible)
subprocess.run(plink + ['DOMAIN=test.kuban-forum.ru PANEL_PASS=testadmin123 EMAIL=furi_wave@mail.ru bash /root/install.sh > /root/install_out.log 2>/root/install_err.log'], capture_output=True, text=True, timeout=600)
print('Run finished')

# Read logs
r = subprocess.run(plink + ['echo "=== STDOUT ===" && cat /root/install_out.log 2>/dev/null && echo "=== STDERR ===" && cat /root/install_err.log 2>/dev/null'], capture_output=True, text=True, timeout=60)
print(r.stdout[-5000:])
print('RC:', r.returncode)

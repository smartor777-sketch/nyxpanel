import subprocess, base64

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'
plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

# Create wrapper that captures all output
wrapper = '''#!/bin/bash
set -o pipefail
DOMAIN=test.kuban-forum.ru PANEL_PASS=testadmin123 EMAIL=furi_wave@mail.ru
export DOMAIN PANEL_PASS EMAIL
bash /root/install.sh 2>&1 | tee /root/install_out.log
exit ${PIPESTATUS[0]}
'''

encoded = base64.b64encode(wrapper.encode('utf-8')).decode('ascii')

r = subprocess.run(plink + [f'echo {encoded} | base64 -d > /root/run_install.sh && chmod +x /root/run_install.sh'], capture_output=True, text=True, timeout=15)
print('Upload wrapper:', 'OK' if r.returncode == 0 else f'rc={r.returncode}')

r = subprocess.run(plink + ['bash /root/run_install.sh'], capture_output=True, text=True, timeout=600)
out = r.stdout
print(out[-5000:] if len(out) > 5000 else out)
if r.returncode != 0:
    print('EXIT CODE:', r.returncode)
    # Also read the log
    r2 = subprocess.run(plink + ['cat /root/install_out.log | head -200'], capture_output=True, text=True, timeout=15)
    if r2.stdout.strip():
        print('=== Full log (first 200 lines):')
        print(r2.stdout)

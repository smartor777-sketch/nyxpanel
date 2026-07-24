import subprocess, base64

host = '2.27.20.211'
pw = 'tZ3oT5iH6awT'
plink = ['plink', '-batch', '-pw', pw, f'root@{host}']

script = '''
import sqlite3
from werkzeug.security import generate_password_hash
db = sqlite3.connect("/opt/proxy-panel/panel.db")
h = generate_password_hash("testadmin123")
db.execute("INSERT OR IGNORE INTO users (username,password_hash,role) VALUES (?,?,?)", ("admin", h, "admin"))
db.commit()
db.close()
print("OK")
'''

encoded = base64.b64encode(script.encode()).decode()
r = subprocess.run(plink + [f'echo {encoded} | base64 -d | python3'], capture_output=True, text=True, timeout=15)
print(r.stdout)
print(r.stderr)

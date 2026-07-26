import sqlite3
db = sqlite3.connect('/opt/proxy-panel/panel.db')
before = db.execute("SELECT count(*) FROM daily_traffic WHERE protocol='hy2'").fetchone()[0]
db.execute("DELETE FROM daily_traffic WHERE protocol='hy2'")
db.execute("DELETE FROM traffic_log WHERE protocol='hy2'")
db.commit()
print(f"Deleted {before} hy2 rows")
remaining = db.execute("SELECT username, protocol, date, bytes_up, bytes_down FROM daily_traffic WHERE username='Merlin' ORDER BY date DESC LIMIT 10").fetchall()
for r in remaining:
    total = r[3] + r[4]
    print(f"{r[0]:10s} {r[1]:6s} {r[2]}  total={total/1024/1024/1024:.2f} GB")

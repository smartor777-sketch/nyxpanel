#!/usr/bin/env python3
import sqlite3
db = sqlite3.connect('/opt/proxy-panel/panel.db')
db.row_factory = sqlite3.Row

print("=== Tables ===")
rows = db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
for r in rows:
    print(r['name'])

print("\n=== Users ===")
rows = db.execute("SELECT username, active FROM users").fetchall()
for r in rows:
    print(r['username'], r['active'])

print("\n=== daily_traffic schema ===")
rows = db.execute("PRAGMA table_info(daily_traffic)").fetchall()
for r in rows:
    print(dict(r))

print("\n=== Recent daily_traffic dates ===")
rows = db.execute("SELECT date, SUM(bytes_up) as up, SUM(bytes_down) as down FROM daily_traffic GROUP BY date ORDER BY date DESC LIMIT 10").fetchall()
for r in rows:
    print(r['date'], r['up'], r['down'])

print("\n=== Traffic per user (last 5 days) ===")
rows = db.execute("SELECT username, date, bytes_up, bytes_down FROM daily_traffic WHERE date >= date('now', '-5 days') ORDER BY date DESC, username LIMIT 20").fetchall()
for r in rows:
    print(r['username'], r['date'], r['bytes_up'], r['bytes_down'])

db.close()

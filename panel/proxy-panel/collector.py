#!/usr/bin/env python3
"""Traffic collector — pulls per-user metrics from protocol APIs"""
import json, sqlite3, subprocess, datetime, os
from pathlib import Path

DB_PATH = "/opt/proxy-panel/panel.db"
BASE_DIR = Path("/root/proxy_users")

def get_db():
    db = sqlite3.connect(DB_PATH)
    db.execute("PRAGMA journal_mode=WAL")
    return db

def get_awg_pubkey_map():
    pk_map = {}
    for d in BASE_DIR.iterdir():
        pk_file = d / ".awg_pubkey"
        if pk_file.exists():
            pk_map[pk_file.read_text().strip()] = d.name
    return pk_map

def collect_all():
    db = get_db()
    today = datetime.date.today().isoformat()
    now = datetime.datetime.now().isoformat()

    # ── Xray ──
    xray_data = {}
    try:
        r = subprocess.run(
            ["xray", "api", "statsquery", "--server=127.0.0.1:10085",
             "-pattern", "user>>>", "-reset"],
            capture_output=True, text=True, timeout=10
        )
        if r.returncode == 0:
            for stat in json.loads(r.stdout).get("stat", []):
                parts = stat.get("name", "").split(">>>")
                if len(parts) >= 4:
                    u, d = parts[1], parts[3]
                    val = stat.get("value", 0)
                    xray_data.setdefault(u, {"up": 0, "down": 0})
                    if d == "downlink":  xray_data[u]["down"] += val
                    elif d == "uplink":  xray_data[u]["up"] += val
    except Exception as e:
        print(f"xray err: {e}")

    # ── Hy2 ──
    hy2_data = {}
    try:
        r = subprocess.run(
            ["curl", "-s", "http://127.0.0.1:30100/traffic"],
            capture_output=True, text=True, timeout=10
        )
        if r.returncode == 0:
            for username, vals in json.loads(r.stdout).items():
                hy2_data[username] = {
                    "up": vals.get("tx", vals.get("upload", 0)),
                    "down": vals.get("rx", vals.get("download", 0)),
                }
    except Exception as e:
        print(f"hy2 err: {e}")

    # ── AWG ──
    awg_data = {}
    try:
        pk_map = get_awg_pubkey_map()
        if pk_map:
            r = subprocess.run(
                ["awg", "show", "awg0"],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode == 0:
                for line in r.stdout.strip().splitlines():
                    parts = line.strip().split()
                    if len(parts) >= 3 and parts[0] in pk_map:
                        uname = pk_map[parts[0]]
                        awg_data[uname] = {"up": int(parts[2]), "down": int(parts[1])}
    except Exception as e:
        print(f"awg err: {e}")

    # ── Merge and store ──
    sources = [("vless", xray_data), ("hy2", hy2_data), ("awg", awg_data)]

    for proto, src_data in sources:
        for username, vals in src_data.items():
            up = vals.get("up", 0)
            down = vals.get("down", 0)
            if up == 0 and down == 0:
                continue
            db.execute(
                """INSERT INTO daily_traffic (username, protocol, date, bytes_up, bytes_down)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(username, protocol, date) DO UPDATE SET
                   bytes_up = bytes_up + ?, bytes_down = bytes_down + ?""",
                (username, proto, today, up, down, up, down)
            )
            db.execute(
                "INSERT INTO traffic_log (username, protocol, bytes_up, bytes_down) VALUES (?, ?, ?, ?)",
                (username, proto, up, down)
            )

    # disable expired users
    expired = db.execute(
        "SELECT username FROM users WHERE expires_at IS NOT NULL AND expires_at < ? AND active = 1",
        (now,)
    ).fetchall()
    for row in expired:
        print(f"Disabling expired user: {row['username']}")
        db.execute("UPDATE users SET active = 0 WHERE username = ?", (row["username"],))

    db.commit()
    db.close()

if __name__ == "__main__":
    collect_all()

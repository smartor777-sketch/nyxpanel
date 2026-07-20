#!/usr/bin/env python3
"""Traffic collector — pulls per-user metrics from protocol APIs"""
import json, sqlite3, subprocess, datetime, os
from pathlib import Path

DB_PATH = "/opt/proxy-panel/panel.db"
BASE_DIR = Path("/root/proxy_users")

XRAY_BIN = "/usr/local/bin/xray"
HY2_API = "http://127.0.0.1:30100/traffic"
AWG_BIN = "/usr/bin/awg"

def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    return db

def get_awg_pubkey_map():
    pk_map = {}
    for d in BASE_DIR.iterdir():
        pk_file = d / ".awg_pubkey"
        if pk_file.exists():
            pk_map[pk_file.read_text().strip()] = d.name
    return pk_map

def collect_xray(db, today):
    """Collect per-user VLESS traffic via xray gRPC stats API."""
    total = 0
    users = db.execute("SELECT username FROM users WHERE active = 1").fetchall()
    for row in users:
        name = row["username"]
        up_val = 0
        down_val = 0
        for direction, label in [("downlink", "down"), ("uplink", "up")]:
            try:
                stat_name = "user>>>" + name + ">>>traffic>>>" + direction
                r = subprocess.run(
                    [XRAY_BIN, "api", "stats", "--server=127.0.0.1:10085",
                     "-name", stat_name],
                    capture_output=True, text=True, timeout=10
                )
                if r.returncode == 0:
                    val = json.loads(r.stdout).get("stat", {}).get("value", 0)
                    if label == "up":
                        up_val += val
                    else:
                        down_val += val
            except Exception as e:
                print(f"xray err {name}/{direction}: {e}")
        if up_val > 0 or down_val > 0:
            db.execute(
                """INSERT INTO daily_traffic (username, protocol, date, bytes_up, bytes_down)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(username, protocol, date) DO UPDATE SET
                   bytes_up = bytes_up + ?, bytes_down = bytes_down + ?""",
                (name, "vless", today, up_val, down_val, up_val, down_val)
            )
            total += 1
    return total

def build_username_map(db):
    """Build lowercase -> canonical username mapping from users table."""
    rows = db.execute("SELECT username FROM users").fetchall()
    return {r["username"].lower(): r["username"] for r in rows}

def collect_hy2(db, today):
    """Collect Hy2 traffic from the traffic stats API."""
    total = 0
    uname_map = build_username_map(db)
    try:
        r = subprocess.run(
            ["curl", "-s", HY2_API],
            capture_output=True, text=True, timeout=10
        )
        if r.returncode == 0:
            data = json.loads(r.stdout)
            for api_name, vals in data.items():
                username = uname_map.get(api_name.lower(), api_name)
                up = vals.get("tx", vals.get("upload", 0))
                down = vals.get("rx", vals.get("download", 0))
                if up > 0 or down > 0:
                    db.execute(
                        """INSERT INTO daily_traffic (username, protocol, date, bytes_up, bytes_down)
                           VALUES (?, ?, ?, ?, ?)
                           ON CONFLICT(username, protocol, date) DO UPDATE SET
                           bytes_up = bytes_up + ?, bytes_down = bytes_down + ?""",
                        (username, "hy2", today, up, down, up, down)
                    )
                    total += 1
    except Exception as e:
        print(f"hy2 err: {e}")
    return total

def collect_awg(db, today):
    """Collect AWG traffic from awg show command.

    AWG transfer values are cumulative since interface creation.
    We store deltas in daily_traffic by comparing with the last snapshot.
    """
    total = 0
    try:
        pk_map = get_awg_pubkey_map()
        if not pk_map:
            return 0
        r = subprocess.run(
            [AWG_BIN, "show", "awg0", "transfer"],
            capture_output=True, text=True, timeout=10
        )
        if r.returncode == 0:
            for line in r.stdout.strip().splitlines():
                parts = line.strip().split()
                if len(parts) >= 3 and parts[0] in pk_map:
                    uname = pk_map[parts[0]]
                    cur_up = int(parts[1])
                    cur_down = int(parts[2])
                    prev = db.execute(
                        "SELECT bytes_up, bytes_down FROM traffic_log WHERE username=? AND protocol='awg' ORDER BY id DESC LIMIT 1",
                        (uname,)
                    ).fetchone()
                    if prev:
                        delta_up = max(0, cur_up - prev["bytes_up"])
                        delta_down = max(0, cur_down - prev["bytes_down"])
                    else:
                        delta_up = cur_up
                        delta_down = cur_down
                    db.execute(
                        "INSERT INTO traffic_log (username, protocol, bytes_up, bytes_down) VALUES (?, ?, ?, ?)",
                        (uname, "awg", cur_up, cur_down)
                    )
                    if delta_up > 0 or delta_down > 0:
                        db.execute(
                            """INSERT INTO daily_traffic (username, protocol, date, bytes_up, bytes_down)
                               VALUES (?, ?, ?, ?, ?)
                               ON CONFLICT(username, protocol, date) DO UPDATE SET
                               bytes_up = bytes_up + ?, bytes_down = bytes_down + ?""",
                            (uname, "awg", today, delta_up, delta_down, delta_up, delta_down)
                        )
                        total += 1
    except Exception as e:
        print(f"awg err: {e}")
    return total

def collect_all():
    db = get_db()
    today = datetime.date.today().isoformat()
    now = datetime.datetime.now().isoformat()
    total_entries = 0

    total_entries += collect_xray(db, today)
    total_entries += collect_hy2(db, today)
    total_entries += collect_awg(db, today)

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
    print(f"Collected: {total_entries} entries")

if __name__ == "__main__":
    collect_all()

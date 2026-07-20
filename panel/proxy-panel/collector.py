#!/usr/bin/env python3
"""Traffic collector — cron script to pull metrics from protocol APIs"""
import json, sqlite3, subprocess, datetime
from pathlib import Path

DB_PATH = "/opt/proxy-panel/panel.db"
BASE_DIR = Path("/root/proxy_users")

def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    return db

def collect_hy2(username):
    """Collect Hysteria 2 traffic from Hy2 logs/metrics."""
    # Hy2 exposes /traffic on its API when enabled
    # For now, placeholder — real collector per protocol later
    return 0, 0

def collect_xray(username):
    """Collect Xray traffic for a user."""
    # Xray has gRPC stats API or can use `xray api stats`
    # Placeholder
    return 0, 0

def collect_all():
    db = get_db()
    users = db.execute("SELECT username FROM users WHERE active = 1").fetchall()
    today = datetime.date.today().isoformat()

    for row in users:
        username = row["username"]
        # Check each protocol's user config exists
        for proto in ["hy2", "vless", "awg", "naive", "mieru", "olcrtc"]:
            bytes_up, bytes_down = 0, 0
            # Try to collect real traffic per protocol
            if proto == "hy2":
                bytes_up, bytes_down = collect_hy2(username)

            if bytes_up > 0 or bytes_down > 0:
                db.execute(
                    """INSERT INTO daily_traffic (username, protocol, date, bytes_up, bytes_down)
                       VALUES (?, ?, ?, ?, ?)
                       ON CONFLICT(username, protocol, date) DO UPDATE SET
                       bytes_up = bytes_up + ?, bytes_down = bytes_down + ?""",
                    (username, proto, today, bytes_up, bytes_down, bytes_up, bytes_down)
                )
                db.execute(
                    "INSERT INTO traffic_log (username, protocol, bytes_up, bytes_down) VALUES (?, ?, ?, ?)",
                    (username, proto, bytes_up, bytes_down)
                )

    # Check and disable expired users
    now = datetime.datetime.now().isoformat()
    expired = db.execute("SELECT username FROM users WHERE expires_at IS NOT NULL AND expires_at < ? AND active = 1", (now,)).fetchall()
    for row in expired:
        print(f"Disabling expired user: {row['username']}")
        db.execute("UPDATE users SET active = 0 WHERE username = ?", (row["username"],))

    db.commit()
    db.close()

if __name__ == "__main__":
    collect_all()

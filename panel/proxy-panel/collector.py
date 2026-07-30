#!/usr/bin/env python3
"""Traffic collector — pulls per-user metrics from protocol APIs"""
import json, sqlite3, subprocess, datetime, os, shutil
from pathlib import Path

DB_PATH = "/opt/proxy-panel/panel.db"
BASE_DIR = Path("/root/proxy_users")

def get_db():
    db = sqlite3.connect(DB_PATH)
    db.execute("PRAGMA journal_mode=WAL")
    return db

EXTRA_PATHS = ["/usr/local/bin", "/usr/bin", "/bin"]
def which(cmd):
    p = shutil.which(cmd)
    if p:
        return p
    for d in EXTRA_PATHS:
        fp = os.path.join(d, cmd)
        if os.path.isfile(fp) and os.access(fp, os.X_OK):
            return fp
    return cmd

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
            [which("xray"), "api", "statsquery", "--server=127.0.0.1:10085",
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

    # ── Hy2 (API returns cumulative totals → compute delta) ──
    hy2_data = {}
    hy2_last_path = "/opt/proxy-panel/hy2_last.json"
    hy2_last = {}
    if os.path.exists(hy2_last_path):
        try:
            with open(hy2_last_path) as f:
                hy2_last = json.load(f)
        except Exception:
            hy2_last = {}
    try:
        username_map = {}
        for row in db.execute("SELECT username FROM users").fetchall():
            username_map[row[0].lower()] = row[0]
        r = subprocess.run(
            [which("curl"), "-s", "http://127.0.0.1:30100/traffic"],
            capture_output=True, text=True, timeout=10
        )
        if r.returncode == 0:
            current_totals = {}
            for raw_username, vals in json.loads(r.stdout).items():
                uname = username_map.get(raw_username.lower(), raw_username)
                cu = int(vals.get("rx", vals.get("upload", 0)))
                cd = int(vals.get("tx", vals.get("download", 0)))
                current_totals[uname] = {"up": cu, "down": cd}
                prev = hy2_last.get(uname, {"up": 0, "down": 0})
                du = max(0, cu - prev.get("up", 0))
                dd = max(0, cd - prev.get("down", 0))
                if du > 0 or dd > 0:
                    hy2_data[uname] = {"up": du, "down": dd}
            try:
                with open(hy2_last_path, "w") as f:
                    json.dump(current_totals, f)
            except Exception as e:
                print(f"hy2 persist err: {e}")
    except Exception as e:
        print(f"hy2 err: {e}")

    # ── AWG (dump format: cumulative totals → compute delta) ──
    awg_data = {}
    awg_last_path = "/opt/proxy-panel/awg_last.json"
    awg_last = {}
    if os.path.exists(awg_last_path):
        try:
            with open(awg_last_path) as f:
                awg_last = json.load(f)
        except Exception:
            awg_last = {}
    try:
        pk_map = get_awg_pubkey_map()
        if pk_map:
            r = subprocess.run(
                [which("awg"), "show", "awg0", "dump"],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode == 0:
                current_totals = {}
                for line in r.stdout.strip().splitlines():
                    parts = line.strip().split()
                    if len(parts) < 8:
                        continue
                    pubkey = parts[0]
                    if pubkey not in pk_map:
                        continue
                    uname = pk_map[pubkey]
                    cu = int(parts[5])
                    cd = int(parts[6])
                    current_totals[uname] = {"up": cu, "down": cd}
                    prev = awg_last.get(uname, {"up": 0, "down": 0})
                    du = max(0, cu - prev.get("up", 0))
                    dd = max(0, cd - prev.get("down", 0))
                    if du > 0 or dd > 0:
                        awg_data[uname] = {"up": du, "down": dd}
                try:
                    with open(awg_last_path, "w") as f:
                        json.dump(current_totals, f)
                except Exception as e:
                    print(f"awg persist err: {e}")
    except Exception as e:
        print(f"awg err: {e}")

    # ── Troy (API returns cumulative totals → compute delta) ──
    troy_data = {}
    troy_last_path = "/opt/proxy-panel/troy_last.json"
    troy_last = {}
    if os.path.exists(troy_last_path):
        try:
            with open(troy_last_path) as f:
                troy_last = json.load(f)
        except Exception:
            troy_last = {}
    try:
        r = subprocess.run(
            [which("trojan-go"), "-api", "list", "-api-addr", "127.0.0.1:10000"],
            capture_output=True, text=True, timeout=10
        )
        if r.returncode == 0:
            import hashlib
            troy_users_file = "/etc/sing-box/trojan_users.json"
            if os.path.exists(troy_users_file):
                with open(troy_users_file) as f:
                    users_map = json.load(f)  # {username: password}
                hash_to_user = {}
                for uname, pwd in users_map.items():
                    h = hashlib.sha224(pwd.encode()).hexdigest()
                    hash_to_user[h] = uname
                current_totals = {}
                for entry in json.loads(r.stdout):
                    h = entry.get("status", {}).get("user", {}).get("hash", "")
                    if h and h in hash_to_user:
                        uname = hash_to_user[h]
                        tt = entry.get("status", {}).get("traffic_total", {})
                        cu = int(tt.get("upload_traffic", 0))
                        cd = int(tt.get("download_traffic", 0))
                        current_totals[uname] = {"up": cu, "down": cd}
                        prev = troy_last.get(uname, {"up": 0, "down": 0})
                        du = max(0, cu - prev.get("up", 0))
                        dd = max(0, cd - prev.get("down", 0))
                        if du > 0 or dd > 0:
                            troy_data[uname] = {"up": du, "down": dd}
                # persist current totals for next run
                try:
                    with open(troy_last_path, "w") as f:
                        json.dump(current_totals, f)
                except Exception as e:
                    print(f"troy persist err: {e}")
    except Exception as e:
        print(f"troy err: {e}")

    # ── Merge and store ──
    sources = [("vless", xray_data), ("hy2", hy2_data), ("awg", awg_data), ("troy", troy_data)]

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

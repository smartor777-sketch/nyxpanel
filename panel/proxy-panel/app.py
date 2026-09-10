#!/usr/bin/env python3
"""NYX Panel — Flask + SQLite"""
import subprocess, os, json, re, sqlite3, datetime, secrets as pysecrets
from pathlib import Path
from flask import Flask, render_template, request, redirect, url_for, send_file, flash, session, jsonify
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = os.environ.get("PANEL_SECRET", os.urandom(16).hex())
PANEL_VERSION = "1.10"

BASE_DIR = Path("/root/proxy_users")
REGISTRY = BASE_DIR / ".registry"
DB_PATH = "/opt/proxy-panel/panel.db"

# Протоколы, которые затрагивает переключатель REALITY mode (whitelist/normal)
REALITY_AFFECTED = [
    ("vless", "VLESS+XHTTP+REALITY"),
]

def is_admin():
    return session.get("self_role") == "admin"

PROTOCOLS = [
    ("hy2",    "Hysteria 2",      "_hy2.json",    "_hy2.png"),
    ("awg",    "AmneziaWG",       "_awg.conf",    "_awg.png"),
    ("naive",  "NaiveProxy",      "_naive.json",  "_naive.png"),
    ("mieru",  "Mieru",           "_mieru.json",  "_mieru.png"),
    ("olcrtc", "olcRTC",          "_olcrtc.json", "_olcrtc.png"),
    ("vless",  "VLESS+XHTTP+REALITY", "_vless.uri", "_vless.png"),
    ("troy",   "Trojan",              "_troyan.json", "_troyan.png"),
]

SCRIPTS = {
    "add_user":      ["bash", "/root/proxy_manager.sh", "add_user"],
    "del_user":      ["bash", "/root/proxy_manager.sh", "del_user"],
    "add_hy2":       ["bash", "/root/proxy_manager.sh", "add_hy2_user"],
    "del_hy2":       ["bash", "/root/proxy_manager.sh", "remove_protocol", "hy2"],
    "add_awg":       ["bash", "/root/proxy_manager.sh", "add_awg_user"],
    "del_awg":       ["bash", "/root/proxy_manager.sh", "remove_protocol", "awg"],
    "add_naive":     ["bash", "/root/proxy_manager.sh", "add_naive_user"],
    "del_naive":     ["bash", "/root/proxy_manager.sh", "remove_protocol", "naive"],
    "add_mieru":     ["bash", "/root/proxy_manager.sh", "add_mieru_user"],
    "del_mieru":     ["bash", "/root/proxy_manager.sh", "remove_protocol", "mieru"],
    "add_olcrtc":    ["bash", "/root/proxy_manager.sh", "add_olcrtc_user"],
    "del_olcrtc":    ["bash", "/root/proxy_manager.sh", "remove_protocol", "olcrtc"],
    "add_vless":     ["bash", "/root/proxy_manager.sh", "add_vless_user"],
    "del_vless":     ["bash", "/root/proxy_manager.sh", "remove_protocol", "vless"],
    "add_troy":      ["bash", "/root/proxy_manager.sh", "add_trojan_user"],
    "del_troy":      ["bash", "/root/proxy_manager.sh", "remove_protocol", "troy"],
}

# --- SQLite ---
def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    return db

def init_db():
    db = get_db()
    db.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT DEFAULT '',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            expires_at TIMESTAMP,
            traffic_limit_bytes INTEGER DEFAULT 0,
            active INTEGER DEFAULT 1,
            note TEXT DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS traffic_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            protocol TEXT NOT NULL,
            bytes_up INTEGER DEFAULT 0,
            bytes_down INTEGER DEFAULT 0,
            recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS daily_traffic (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            protocol TEXT NOT NULL,
            date TEXT NOT NULL,
            bytes_up INTEGER DEFAULT 0,
            bytes_down INTEGER DEFAULT 0,
            UNIQUE(username, protocol, date)
        );
    """)
    try:
        db.execute("ALTER TABLE users ADD COLUMN password_hash TEXT DEFAULT ''")
    except sqlite3.OperationalError:
        pass
    try:
        db.execute("ALTER TABLE users ADD COLUMN role TEXT DEFAULT 'user'")
    except sqlite3.OperationalError:
        pass
    try:
        db.execute("ALTER TABLE users ADD COLUMN can_reset_traffic INTEGER DEFAULT 0")
    except sqlite3.OperationalError:
        pass
    db.commit()
    migrate_from_registry(db)
    db.close()

def migrate_from_registry(db):
    """Migrate existing file-based users to SQLite."""
    if not REGISTRY.exists():
        return
    existing = {row["username"] for row in db.execute("SELECT username FROM users").fetchall()}
    for line in REGISTRY.read_text().strip().splitlines():
        line = line.strip()
        if line and line not in existing:
            db.execute("INSERT OR IGNORE INTO users (username) VALUES (?)", (line,))
    db.commit()

# --- File helpers (backward compat) ---
def get_file_users():
    if not REGISTRY.exists():
        return []
    users = []
    for line in REGISTRY.read_text().strip().splitlines():
        line = line.strip()
        if not line or line == "admin":
            continue
        protos = {}
        for key, name, cfg, qr in PROTOCOLS:
            f = BASE_DIR / line / f"{line}{cfg}"
            protos[key] = f.exists()
        users.append({"name": line, "protocols": protos, "active": True, "expires_at": None})
    return users

def get_db_users():
    db = get_db()
    rows = db.execute("SELECT username, expires_at, active, password_hash, can_reset_traffic FROM users WHERE username != 'admin' ORDER BY username").fetchall()
    db.close()
    users = []
    for row in rows:
        protos = {}
        for key, name, cfg, qr in PROTOCOLS:
            f = BASE_DIR / row["username"] / f"{row['username']}{cfg}"
            protos[key] = f.exists()
        users.append({
            "name": row["username"],
            "protocols": protos,
            "active": bool(row["active"]),
            "expires_at": row["expires_at"],
            "has_password": bool(row["password_hash"]),
            "can_reset_traffic": bool(row["can_reset_traffic"]),
        })
    return users

def call_script(name, username):
    cmd = SCRIPTS.get(name)
    if not cmd:
        return False, "Unknown command"
    env = os.environ.copy()
    env["TERM"] = "linux"
    try:
        proc = subprocess.run(
            cmd + [username],
            capture_output=True, encoding="utf-8", timeout=120, env=env
        )
        out = proc.stdout or ""
        err = proc.stderr or ""
        out = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', out).strip()
        err = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', err).strip()
        if proc.returncode == 0:
            return True, out or "OK"
        return False, err or out or "Error"
    except subprocess.TimeoutExpired:
        return False, "Timeout"
    except Exception as e:
        return False, str(e)

def get_reality_state():
    """Текущее состояние REALITY mode (normal|whitelist) — источник истины = xray config."""
    state = {"mode": "normal", "target": "", "sni": "", "affected": "vless"}
    try:
        proc = subprocess.run(
            ["bash", "/root/proxy_manager.sh", "reality_status"],
            capture_output=True, text=True, timeout=30
        )
        for line in (proc.stdout or "").splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                state[k.strip()] = v.strip()
    except Exception:
        pass
    return state

@app.route("/self/reality/toggle", methods=["POST"])
def reality_toggle():
    if not is_admin():
        return redirect("/self/login")
    state = get_reality_state()
    new_mode = "whitelist" if state.get("mode") != "whitelist" else "normal"
    env = os.environ.copy()
    env["TERM"] = "linux"
    try:
        proc = subprocess.run(
            ["bash", "/root/proxy_manager.sh", "set_reality_mode", new_mode],
            capture_output=True, encoding="utf-8", timeout=120, env=env
        )
        out = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', proc.stdout or "").strip()
        err = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', proc.stderr or "").strip()
        if proc.returncode == 0:
            flash(out or "OK", "ok")
        else:
            flash(err or out or "Error", "error")
    except subprocess.TimeoutExpired:
        flash("Timeout", "error")
    except Exception as e:
        flash(str(e), "error")
    return redirect("/self/")

@app.route("/")
def index():
    return redirect("/self/login")

@app.route("/self/user/add", methods=["POST"])
def user_add():
    if not is_admin():
        return redirect("/self/login")
    name = request.form.get("username", "").strip()
    if not re.match(r'^[a-zA-Z0-9_-]+$', name):
        flash("Invalid username", "error")
        return redirect(request.referrer or "/self/")
    ok, msg = call_script("add_user", name)
    if ok:
        db = get_db()
        db.execute("INSERT OR IGNORE INTO users (username) VALUES (?)", (name,))
        db.commit()
        db.close()
    flash(msg[:300], "ok" if ok else "error")
    return redirect(request.referrer or "/self/")

@app.route("/self/user/<name>/delete", methods=["POST"])
def user_delete(name):
    if not is_admin():
        return redirect("/self/login")
    ok, msg = call_script("del_user", name)
    if ok:
        db = get_db()
        db.execute("DELETE FROM users WHERE username = ?", (name,))
        db.commit()
        db.close()
    flash(msg[:300], "ok" if ok else "error")
    return redirect(request.referrer or "/self/")

@app.route("/self/user/<name>/protocol/<proto>/add", methods=["POST"])
def proto_add(name, proto):
    if not is_admin():
        return redirect("/self/login")
    script_map = {
        "hy2": "add_hy2", "awg": "add_awg", "naive": "add_naive",
        "mieru": "add_mieru", "olcrtc": "add_olcrtc", "vless": "add_vless", "troy": "add_troy",
    }
    sname = script_map.get(proto)
    if not sname:
        flash("Unknown protocol", "error")
        return redirect(request.referrer or "/self/")
    ok, msg = call_script(sname, name)
    flash(msg[:300], "ok" if ok else "error")
    return redirect(request.referrer or "/self/")

@app.route("/self/user/<name>/protocol/<proto>/delete", methods=["POST"])
def proto_delete(name, proto):
    if not is_admin():
        return redirect("/self/login")
    ok, msg = call_script(f"del_{proto}", name)
    flash(msg[:300], "ok" if ok else "error")
    return redirect(request.referrer or "/self/")

@app.route("/self/user/<name>/config/<proto>")
def get_config(name, proto):
    if not is_admin():
        return redirect("/self/login")
    suffix_map = dict((p[0], p[2]) for p in PROTOCOLS)
    suffix = suffix_map.get(proto)
    if not suffix:
        return "Not found", 404
    path = BASE_DIR / name / f"{name}{suffix}"
    if not path.exists():
        return "Not found", 404
    return send_file(str(path), as_attachment=True, download_name=f"{name}{suffix}")

@app.route("/self/user/<name>/qr/<proto>")
def get_qr(name, proto):
    if not is_admin():
        return redirect("/self/login")
    suffix_map = dict((p[0], p[3]) for p in PROTOCOLS)
    suffix = suffix_map.get(proto)
    if not suffix:
        return "Not found", 404
    path = BASE_DIR / name / f"{name}{suffix}"
    if not path.exists():
        return "Not found", 404
    return send_file(str(path), mimetype="image/png")

@app.route("/self/user/<name>/expiry", methods=["POST"])
def set_expiry(name):
    if not is_admin():
        return redirect("/self/login")
    expires = request.form.get("expires", "").strip()
    db = get_db()
    if expires:
        try:
            dt = datetime.datetime.strptime(expires, "%Y-%m-%d")
            db.execute("UPDATE users SET expires_at = ? WHERE username = ?", (dt.isoformat(), name))
            flash("Expiry set", "ok")
        except ValueError:
            flash("Invalid date format (YYYY-MM-DD)", "error")
    else:
        db.execute("UPDATE users SET expires_at = NULL WHERE username = ?", (name,))
        flash("Expiry cleared", "ok")
    db.commit()
    db.close()
    return redirect(request.referrer or "/self/")

@app.route("/self/user/<name>/toggle", methods=["POST"])
def toggle_user(name):
    if not is_admin():
        return redirect("/self/login")
    db = get_db()
    row = db.execute("SELECT active FROM users WHERE username = ?", (name,)).fetchone()
    if row:
        new = 0 if row["active"] else 1
        db.execute("UPDATE users SET active = ? WHERE username = ?", (new, name))
        db.commit()
    db.close()
    return redirect(request.referrer or "/self/")

@app.route("/self/user/<name>/reset-traffic", methods=["POST"])
def reset_traffic(name):
    self_user = session.get("self_user")
    role = session.get("self_role", "user")
    if not self_user:
        return redirect("/self/login")
    if role != "admin":
        db = get_db()
        row = db.execute("SELECT can_reset_traffic FROM users WHERE username = ?", (self_user,)).fetchone()
        can_reset = bool(row and row["can_reset_traffic"])
        db.close()
        if not can_reset or self_user != name:
            return redirect("/self/")
    db = get_db()
    db.execute("DELETE FROM daily_traffic WHERE username = ?", (name,))
    db.execute("DELETE FROM traffic_log WHERE username = ?", (name,))
    db.commit()
    db.close()
    for f in ["awg_last.json", "hy2_last.json", "troy_last.json"]:
        path = f"/opt/proxy-panel/{f}"
        if os.path.exists(path):
            try:
                with open(path) as fh:
                    data = json.load(fh)
                if name in data or name.lower() in data:
                    key = name if name in data else name.lower()
                    del data[key]
                    with open(path, "w") as fh:
                        json.dump(data, fh)
            except Exception:
                pass
    flash(f"Traffic reset for {name}", "ok")
    return redirect(request.referrer or "/self/")

@app.route("/self/user/<name>/set-reset-traffic", methods=["POST"])
def set_reset_traffic(name):
    if not is_admin():
        return redirect("/self/login")
    enabled = request.form.get("enabled") == "1"
    db = get_db()
    db.execute("UPDATE users SET can_reset_traffic = ? WHERE username = ?", (1 if enabled else 0, name))
    db.commit()
    db.close()
    flash(f"Reset traffic {'enabled' if enabled else 'disabled'} for {name}", "ok")
    return redirect(request.referrer or "/self/")

@app.route("/self/user/<name>/password", methods=["POST"])
def set_password(name):
    if not is_admin():
        return redirect("/self/login")
    pwd = request.form.get("password", "").strip()
    if not pwd:
        flash("Password cannot be empty", "error")
        return redirect(request.referrer or "/self/")
    db = get_db()
    db.execute("UPDATE users SET password_hash = ? WHERE username = ?",
               (generate_password_hash(pwd), name))
    db.commit()
    db.close()
    flash(f"Password set for {name}", "ok")
    return redirect(request.referrer or "/self/")

# --- Self-service dashboard ---
@app.route("/self/login", methods=["GET", "POST"])
def self_login():
    if request.method == "POST":
        name = request.form.get("username", "").strip()
        pwd = request.form.get("password", "")
        db = get_db()
        row = db.execute("SELECT username, password_hash, active, role FROM users WHERE username = ?", (name,)).fetchone()
        db.close()
        if row and row["active"] and row["password_hash"] and check_password_hash(row["password_hash"], pwd):
            session["self_user"] = row["username"]
            session["self_role"] = row["role"]
            return redirect(url_for("self_dashboard"))
        flash("Invalid credentials or user inactive", "error")
        return redirect(url_for("self_login"))
    return render_template("self_login.html", version=PANEL_VERSION)

@app.route("/self/logout")
def self_logout():
    session.pop("self_user", None)
    return redirect(url_for("self_login"))

@app.route("/self/change-password", methods=["POST"])
def self_change_password():
    name = session.get("self_user")
    if not name:
        return jsonify({"error": "unauthorized"}), 401
    data = request.get_json(silent=True) or {}
    current = data.get("current_password", "")
    new = data.get("new_password", "")
    if not current or not new:
        return jsonify({"error": "missing fields"}), 400
    if len(new) < 4:
        return jsonify({"error": "password too short"}), 400
    db = get_db()
    row = db.execute("SELECT password_hash FROM users WHERE username = ?", (name,)).fetchone()
    if not row or not row["password_hash"] or not check_password_hash(row["password_hash"], current):
        db.close()
        return jsonify({"error": "wrong current password"}), 403
    db.execute("UPDATE users SET password_hash = ? WHERE username = ?", (generate_password_hash(new), name))
    db.commit()
    db.close()
    return jsonify({"ok": True})

@app.route("/self/manual")
def self_manual():
    name = session.get("self_user")
    if not name:
        return redirect(url_for("self_login"))
    apk_url = url_for("self_download_apk")
    return render_template("manual.html", apk_url=apk_url, version=PANEL_VERSION)

@app.route("/self/olcrtc-windows")
def self_olcrtc_windows():
    name = session.get("self_user")
    if not name:
        return redirect(url_for("self_login"))
    return render_template("olcrtc_windows.html")

@app.route("/self/download/apk")
def self_download_apk():
    apk_path = "/opt/proxy-panel/static/OlcboxME-1.0.2.apk"
    if os.path.exists(apk_path):
        return send_file(apk_path, as_attachment=True, download_name="OlcboxME-1.0.2.apk")
    return "APK not found", 404

@app.route("/self/")
def self_dashboard():
    name = session.get("self_user")
    if not name:
        return redirect(url_for("self_login"))
    role = session.get("self_role", "user")
    db = get_db()
    if role == "admin":
        db_users = get_db_users()
        db.close()
        reality = get_reality_state()
        return render_template("self_admin.html", users=db_users, protocols=PROTOCOLS,
                               admin_name=name, version=PANEL_VERSION,
                               reality=reality, reality_affected=REALITY_AFFECTED)
    row = db.execute("SELECT username, expires_at, active, created_at, traffic_limit_bytes, can_reset_traffic FROM users WHERE username = ?", (name,)).fetchone()
    if not row or not row["active"]:
        session.pop("self_user", None)
        return redirect(url_for("self_login"))
    protos = {}
    for key, pname, cfg, qr in PROTOCOLS:
        f = BASE_DIR / name / f"{name}{cfg}"
        protos[key] = {"active": f.exists(), "name": pname, "cfg": cfg, "qr": qr}
    traffic = db.execute(
        "SELECT SUM(bytes_up) as up, SUM(bytes_down) as down FROM daily_traffic WHERE username = ?",
        (name,)
    ).fetchone()
    db.close()
    total = (traffic["up"] or 0) + (traffic["down"] or 0)
    limit = row["traffic_limit_bytes"] or 0
    percent = round(total / limit * 100, 1) if limit > 0 else None
    return render_template("self.html", user=row, protocols=protos, traffic=total, percent=percent, version=PANEL_VERSION, protocols_list=PROTOCOLS, can_reset_traffic=bool(row["can_reset_traffic"]))

@app.route("/self/config/<proto>")
@app.route("/self/config/<name>/<proto>")
def self_config(proto, name=None):
    self_user = session.get("self_user")
    if not self_user:
        return redirect(url_for("self_login"))
    role = session.get("self_role", "user")
    if name and role != "admin":
        return "Forbidden", 403
    target = name or self_user
    suffix_map = dict((p[0], p[2]) for p in PROTOCOLS)
    suffix = suffix_map.get(proto)
    if not suffix:
        return "Not found", 404
    path = BASE_DIR / target / f"{target}{suffix}"
    if not path.exists():
        return "Not found", 404
    return send_file(str(path), as_attachment=True, download_name=f"{target}{suffix}")

@app.route("/self/qr/<proto>")
@app.route("/self/qr/<name>/<proto>")
def self_qr(proto, name=None):
    self_user = session.get("self_user")
    if not self_user:
        return redirect(url_for("self_login"))
    role = session.get("self_role", "user")
    if name and role != "admin":
        return "Forbidden", 403
    target = name or self_user
    suffix_map = dict((p[0], p[3]) for p in PROTOCOLS)
    suffix = suffix_map.get(proto)
    if not suffix:
        return "Not found", 404
    path = BASE_DIR / target / f"{target}{suffix}"
    if not path.exists():
        return "Not found", 404
    return send_file(str(path), mimetype="image/png")

# --- Telegram WEB Proxy (tproxy) ---
TPROXY_PROFILES_PATH = "/etc/tproxy-server/profiles.json"
TPROXY_CONFIG_PATH = "/etc/tproxy-server/config.json"

def tproxy_read_profiles():
    try:
        with open(TPROXY_PROFILES_PATH) as f:
            return json.load(f).get("profiles", [])
    except Exception:
        return []

def tproxy_write_profiles(profiles):
    with open(TPROXY_PROFILES_PATH, "w") as f:
        json.dump({"profiles": profiles}, f, indent=2)

def tproxy_restart():
    subprocess.run(["systemctl", "restart", "tproxy-server"], capture_output=True, timeout=15)

def tproxy_get_hostname():
    try:
        with open(TPROXY_CONFIG_PATH) as f:
            return json.load(f).get("public_hostname", "")
    except Exception:
        return ""

def tproxy_get_used_ports():
    """Get ports already in use by mtproxy instances."""
    ports = set()
    try:
        result = subprocess.run(
            ["ss", "-tlnp"], capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            if "mtproto-proxy" in line:
                parts = line.split()
                for p in parts:
                    if p.endswith(":") or ":" not in p:
                        continue
                    port = p.rsplit(":", 1)[-1]
                    if port.isdigit():
                        ports.add(int(port))
    except Exception:
        pass
    return ports

def tproxy_find_next_port():
    """Find next available port starting from 2401."""
    used = tproxy_get_used_ports()
    for port in range(2401, 2500):
        if port not in used:
            return port
    return None

def tproxy_create_mtproxy(name, secret, port):
    """Create an mtproxy instance: env, script, service, start, firewall."""
    env_path = f"/etc/mtproxy/mtproxy-{name}.env"
    script_path = f"/usr/local/bin/mtproxy-{name}.sh"
    service_path = f"/etc/systemd/system/mtproxy-{name}.service"
    proxy_port = port + 1000

    with open(env_path, "w") as f:
        f.write(f"MTPROXY_SECRET={secret}\nMTPROXY_WORKERS=1\nMTPROXY_MAX_CONNECTIONS=4096\n")

    with open(script_path, "w") as f:
        f.write(f"""#!/bin/bash
set -a
source {env_path}
set +a
exec /opt/MTProxy/objs/bin/mtproto-proxy -u mtproxy -p {proxy_port} -H {port} -S $MTPROXY_SECRET --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M $MTPROXY_WORKERS -C $MTPROXY_MAX_CONNECTIONS
""")
    os.chmod(script_path, 0o755)

    with open(service_path, "w") as f:
        f.write(f"""[Unit]
Description=MTProxy backend (profile {name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtproxy
Group=mtproxy
WorkingDirectory=/opt/MTProxy
ExecStart={script_path}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectProc=invisible
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
""")

    subprocess.run(["systemctl", "daemon-reload"], capture_output=True, timeout=10)
    subprocess.run(["systemctl", "enable", f"mtproxy-{name}"], capture_output=True, timeout=10)
    subprocess.run(["systemctl", "start", f"mtproxy-{name}"], capture_output=True, timeout=10)
    tproxy_update_firewall()

def tproxy_delete_mtproxy(name):
    """Stop and remove an mtproxy instance."""
    subprocess.run(["systemctl", "stop", f"mtproxy-{name}"], capture_output=True, timeout=10)
    subprocess.run(["systemctl", "disable", f"mtproxy-{name}"], capture_output=True, timeout=10)
    subprocess.run(["systemctl", "daemon-reload"], capture_output=True, timeout=10)
    for path in [
        f"/etc/mtproxy/mtproxy-{name}.env",
        f"/usr/local/bin/mtproxy-{name}.sh",
        f"/etc/systemd/system/mtproxy-{name}.service",
    ]:
        try:
            os.remove(path)
        except Exception:
            pass
    tproxy_update_firewall()

def tproxy_update_firewall():
    """Update nftables to block all mtproxy backend ports from external access."""
    used = tproxy_get_used_ports()
    used.add(8888)
    ports_str = ", ".join(str(p) for p in sorted(used))
    cmd = f"nft flush chain inet tproxy_backend local_backend && nft add rule inet tproxy_backend local_backend iifname != lo tcp dport {{ {ports_str} }} drop"
    subprocess.run(cmd, shell=True, capture_output=True, timeout=10)

@app.route("/self/tproxy")
def tproxy_list():
    if not is_admin():
        return redirect("/self/login")
    profiles = tproxy_read_profiles()
    hostname = tproxy_get_hostname()
    return render_template("tproxy_profiles.html", profiles=profiles, hostname=hostname,
                           admin_name=session.get("self_user"), version=PANEL_VERSION)

@app.route("/self/tproxy/add", methods=["POST"])
def tproxy_add():
    if not is_admin():
        return redirect("/self/login")
    name = request.form.get("name", "").strip()
    secret = request.form.get("secret", "").strip()
    carrier = request.form.get("carrier_mode", "https").strip()
    if carrier not in ("https", "https-lanes", "websocket", "websocket-lanes"):
        carrier = "https"
    if not name or not re.match(r'^[a-zA-Z0-9_-]+$', name):
        flash("Invalid profile name", "error")
        return redirect("/self/tproxy")
    profiles = tproxy_read_profiles()
    if any(p["name"] == name for p in profiles):
        flash(f"Profile '{name}' already exists", "error")
        return redirect("/self/tproxy")
    if not secret:
        secret = pysecrets.token_hex(16)
    if len(secret) not in (32, 34) or not re.match(r'^[0-9a-f]+$', secret):
        flash("Secret must be 32 hex chars (optionally prefixed with dd)", "error")
        return redirect("/self/tproxy")
    port = tproxy_find_next_port()
    if not port:
        flash("No available ports for new mtproxy instance", "error")
        return redirect("/self/tproxy")
    profiles.append({"name": name, "secret": secret, "backend": f"127.0.0.1:{port}", "carrier_mode": carrier})
    tproxy_write_profiles(profiles)
    tproxy_create_mtproxy(name, secret, port)
    tproxy_restart()
    flash(f"Profile '{name}' created (mtproxy on :{port})", "ok")
    return redirect("/self/tproxy")

@app.route("/self/tproxy/<name>/delete", methods=["POST"])
def tproxy_delete(name):
    if not is_admin():
        return redirect("/self/login")
    profiles = tproxy_read_profiles()
    target = next((p for p in profiles if p["name"] == name), None)
    if target and name != "default":
        tproxy_delete_mtproxy(name)
    profiles = [p for p in profiles if p["name"] != name]
    tproxy_write_profiles(profiles)
    tproxy_restart()
    flash(f"Profile '{name}' deleted", "ok")
    return redirect("/self/tproxy")

@app.route("/self/tproxy/<name>/set-mode", methods=["POST"])
def tproxy_set_mode(name):
    if not is_admin():
        return redirect("/self/login")
    carrier = request.form.get("carrier_mode", "https").strip()
    if carrier not in ("https", "https-lanes", "websocket", "websocket-lanes"):
        flash("Invalid carrier mode", "error")
        return redirect("/self/tproxy")
    profiles = tproxy_read_profiles()
    for p in profiles:
        if p["name"] == name:
            p["carrier_mode"] = carrier
            break
    tproxy_write_profiles(profiles)
    tproxy_restart()
    flash(f"Mode changed to {carrier}", "ok")
    return redirect("/self/tproxy")

@app.route("/self/tproxy/<name>/edit", methods=["POST"])
def tproxy_edit(name):
    if not is_admin():
        return redirect("/self/login")
    secret = request.form.get("secret", "").strip()
    carrier = request.form.get("carrier_mode", "https").strip()
    if carrier not in ("https", "https-lanes", "websocket", "websocket-lanes"):
        carrier = "https"
    profiles = tproxy_read_profiles()
    for p in profiles:
        if p["name"] == name:
            if secret and secret != p["secret"]:
                if len(secret) not in (32, 34) or not re.match(r'^[0-9a-f]+$', secret):
                    flash("Secret must be 32 hex chars", "error")
                    return redirect("/self/tproxy")
                tproxy_delete_mtproxy(name)
                port = tproxy_find_next_port()
                if not port:
                    flash("No available ports", "error")
                    return redirect("/self/tproxy")
                p["secret"] = secret
                p["backend"] = f"127.0.0.1:{port}"
                tproxy_create_mtproxy(name, secret, port)
            p["carrier_mode"] = carrier
            break
    tproxy_write_profiles(profiles)
    tproxy_restart()
    flash(f"Profile '{name}' updated", "ok")
    return redirect("/self/tproxy")

@app.route("/self/tproxy/<name>/info")
def tproxy_info(name):
    if not is_admin():
        return redirect("/self/login")
    profiles = tproxy_read_profiles()
    hostname = tproxy_get_hostname()
    for p in profiles:
        if p["name"] == name:
            return jsonify({"name": name, "host": hostname, "key": p["secret"], "carrier_mode": p.get("carrier_mode", "https")})
    return jsonify({"error": "not found"}), 404

# --- API v1 ---
@app.route("/self/api/traffic")
@app.route("/self/api/traffic/<name>")
def self_api_traffic(name=None):
    return api_traffic(name)

@app.route("/self/api/v1/users")
def api_users():
    db = get_db()
    rows = db.execute("SELECT username, created_at, expires_at, active, note FROM users ORDER BY username").fetchall()
    db.close()
    return json.dumps([dict(r) for r in rows], ensure_ascii=False, default=str)

@app.route("/self/api/v1/traffic/totals")
def api_traffic_totals():
    db = get_db()
    rows = db.execute(
        "SELECT username, SUM(bytes_up) as bytes_up, SUM(bytes_down) as bytes_down FROM daily_traffic GROUP BY username ORDER BY username"
    ).fetchall()
    db.close()
    return json.dumps([dict(r) for r in rows], default=str)

@app.route("/self/api/v1/traffic")
@app.route("/self/api/v1/traffic/<name>")
def api_traffic(name=None):
    days = request.args.get("days", 30, type=int)
    db = get_db()
    if days == 0:
        if name:
            rows = db.execute(
                "SELECT username, date, protocol, bytes_up, bytes_down FROM daily_traffic WHERE username = ? ORDER BY date",
                (name,)
            ).fetchall()
        else:
            rows = db.execute(
                "SELECT username, date, protocol, bytes_up, bytes_down FROM daily_traffic ORDER BY date, username"
            ).fetchall()
    elif name:
        rows = db.execute(
            "SELECT username, date, protocol, bytes_up, bytes_down FROM daily_traffic WHERE username = ? AND date >= date('now', ?) ORDER BY date",
            (name, f"-{days} days")
        ).fetchall()
    else:
        rows = db.execute(
            "SELECT username, date, protocol, bytes_up, bytes_down FROM daily_traffic WHERE date >= date('now', ?) ORDER BY date, username",
            (f"-{days} days",)
        ).fetchall()
    db.close()
    return json.dumps([dict(r) for r in rows], default=str)

@app.route("/self/api/v1/sub/<name>")
def api_subscription(name):
    ua = (request.headers.get("User-Agent", "") or "").lower()
    base = BASE_DIR / name
    if not base.exists():
        return "User not found", 404

    links = []
    for key, pname, cfg_suffix, qr_suffix in PROTOCOLS:
        cfg_path = base / f"{name}{cfg_suffix}"
        if cfg_path.exists():
            content = cfg_path.read_text().strip()
            if cfg_suffix == "_vless.uri":
                links.append(content)
            elif cfg_suffix == "_naive.json":
                try:
                    j = json.loads(content)
                    links.append(f"naive+https://{j['outbounds'][0]['username']}:{j['outbounds'][0]['password']}@{j['outbounds'][0]['server']}:443/?padding=false#Naive-{name}")
                except:
                    pass
            elif cfg_suffix == "_hy2.json":
                try:
                    j = json.loads(content)
                    o = j['outbounds'][0]
                    links.append(f"hy2://{o['password']}@{o['server']}:{o['server_port']}?obfs={o['obfs']['type']}&obfs-password={o['obfs']['password']}#Hy2-{name}")
                except:
                    pass
            elif cfg_suffix == "_troyan.json":
                try:
                    j = json.loads(content)
                    o = j['outbounds'][0]
                    links.append(f"trojan://{o['password']}@{o['server']}:{o['server_port']}?security=tls&sni={o['sni']}&type=tcp&headerType=none#Troyan-{name}")
                except:
                    pass
    import base64
    base_url = request.url_root.rstrip("/")
    standalone_path = base / f"{name}_mieru_standalone.json"
    if standalone_path.exists():
        links.append(f"mieru config: {base_url}/self/user/{name}/config/mieru")
    payload = base64.b64encode("\n".join(links).encode()).decode()

    # All major clients (V2RayNG, NekoBox, Hiddify, Sing-box, Clash)
    # expect plain base64 in response body
    return payload, 200, {"Content-Type": "text/plain; charset=utf-8"}

if __name__ == "__main__":
    init_db()
    app.run(host="127.0.0.1", port=5000, debug=False)

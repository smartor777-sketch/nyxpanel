#!/usr/bin/env python3
"""NYX Panel — Flask + SQLite"""
import subprocess, os, json, re, sqlite3, datetime
from pathlib import Path
from flask import Flask, render_template, request, redirect, url_for, send_file, flash, session
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = os.environ.get("PANEL_SECRET", os.urandom(16).hex())
PANEL_VERSION = "1.05"

class PrefixMiddleware:
    def __init__(self, app, prefix='/panel'):
        self.app = app
        self.prefix = prefix
    def __call__(self, environ, start_response):
        path = environ['PATH_INFO']
        if path.startswith('/self'):
            return self.app(environ, start_response)
        if path.startswith(self.prefix):
            environ['PATH_INFO'] = path[len(self.prefix):]
            environ['SCRIPT_NAME'] = self.prefix
            return self.app(environ, start_response)
        start_response('404', [('Content-Type', 'text/plain')])
        return [b'Not Found']

app.wsgi_app = PrefixMiddleware(app.wsgi_app)

BASE_DIR = Path("/root/proxy_users")
REGISTRY = BASE_DIR / ".registry"
DB_PATH = "/opt/proxy-panel/panel.db"

def is_admin():
    return session.get("self_role") == "admin" or request.headers.get("REMOTE_USER")

PROTOCOLS = [
    ("hy2",    "Hysteria 2",      "_hy2.json",    "_hy2.png"),
    ("awg",    "AmneziaWG",       "_awg.conf",    "_awg.png"),
    ("naive",  "NaiveProxy",      "_naive.json",  "_naive.png"),
    ("mieru",  "Mieru",           "_mieru.json",  "_mieru.png"),
    ("olcrtc", "olcRTC",          "_olcrtc.yaml", "_olcrtc.png"),
    ("vless",  "VLESS+XHTTP+REALITY", "_vless.uri", "_vless.png"),
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
    rows = db.execute("SELECT username, expires_at, active FROM users WHERE username != 'admin' ORDER BY username").fetchall()
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
            capture_output=True, text=True, timeout=120, env=env
        )
        if proc.returncode == 0:
            return True, proc.stdout or "OK"
        return False, proc.stderr or proc.stdout or "Error"
    except subprocess.TimeoutExpired:
        return False, "Timeout"
    except Exception as e:
        return False, str(e)

@app.route("/")
def index():
    if not is_admin():
        return redirect("/self/login")
    db_users = get_db_users()
    admin_name = session.get("self_user") or request.headers.get("REMOTE_USER") or "Admin"
    return render_template("index.html", users=db_users, protocols=PROTOCOLS, version=PANEL_VERSION, admin_name=admin_name)

@app.route("/user/add", methods=["POST"])
def user_add():
    if not is_admin():
        return redirect("/self/login")
    name = request.form.get("username", "").strip()
    if not re.match(r'^[a-zA-Z0-9_-]+$', name):
        flash("Invalid username", "error")
        return redirect(url_for("index"))
    ok, msg = call_script("add_user", name)
    if ok:
        db = get_db()
        db.execute("INSERT OR IGNORE INTO users (username) VALUES (?)", (name,))
        db.commit()
        db.close()
    flash(msg[:300], "ok" if ok else "error")
    return redirect(url_for("index"))

@app.route("/user/<name>/delete", methods=["POST"])
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
    return redirect(url_for("index"))

@app.route("/user/<name>/protocol/<proto>/add", methods=["POST"])
def proto_add(name, proto):
    if not is_admin():
        return redirect("/self/login")
    script_map = {
        "hy2": "add_hy2", "awg": "add_awg", "naive": "add_naive",
        "mieru": "add_mieru", "olcrtc": "add_olcrtc", "vless": "add_vless",
    }
    sname = script_map.get(proto)
    if not sname:
        flash("Unknown protocol", "error")
        return redirect(url_for("index"))
    ok, msg = call_script(sname, name)
    flash(msg[:300], "ok" if ok else "error")
    return redirect(url_for("index"))

@app.route("/user/<name>/protocol/<proto>/delete", methods=["POST"])
def proto_delete(name, proto):
    if not is_admin():
        return redirect("/self/login")
    ok, msg = call_script(f"del_{proto}", name)
    flash(msg[:300], "ok" if ok else "error")
    return redirect(url_for("index"))

@app.route("/user/<name>/config/<proto>")
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
    return send_file(str(path), as_attachment=True, download_name=f"{name}_{proto}{suffix}")

@app.route("/user/<name>/qr/<proto>")
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

@app.route("/user/<name>/expiry", methods=["POST"])
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
    return redirect(url_for("index"))

@app.route("/user/<name>/toggle", methods=["POST"])
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
    return redirect(url_for("index"))

@app.route("/user/<name>/password", methods=["POST"])
def set_password(name):
    if not is_admin():
        return redirect("/self/login")
    pwd = request.form.get("password", "").strip()
    if not pwd:
        flash("Password cannot be empty", "error")
        return redirect(url_for("index"))
    db = get_db()
    db.execute("UPDATE users SET password_hash = ? WHERE username = ?",
               (generate_password_hash(pwd), name))
    db.commit()
    db.close()
    flash(f"Password set for {name}", "ok")
    return redirect(url_for("index"))

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
        return render_template("self_admin.html", users=db_users, protocols=PROTOCOLS, admin_name=name, version=PANEL_VERSION)
    row = db.execute("SELECT username, expires_at, active, created_at, traffic_limit_bytes FROM users WHERE username = ?", (name,)).fetchone()
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
    return render_template("self.html", user=row, protocols=protos, traffic=total, percent=percent, version=PANEL_VERSION)

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
    return send_file(str(path), as_attachment=True, download_name=f"{target}_{proto}{suffix}")

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

# --- API v1 ---
@app.route("/api/v1/users")
def api_users():
    db = get_db()
    rows = db.execute("SELECT username, created_at, expires_at, active, note FROM users ORDER BY username").fetchall()
    db.close()
    return json.dumps([dict(r) for r in rows], ensure_ascii=False, default=str)

@app.route("/api/v1/traffic/totals")
def api_traffic_totals():
    db = get_db()
    rows = db.execute(
        "SELECT username, SUM(bytes_up) as bytes_up, SUM(bytes_down) as bytes_down FROM daily_traffic GROUP BY username ORDER BY username"
    ).fetchall()
    db.close()
    return json.dumps([dict(r) for r in rows], default=str)

@app.route("/api/v1/traffic")
@app.route("/api/v1/traffic/<name>")
def api_traffic(name=None):
    days = request.args.get("days", 30, type=int)
    db = get_db()
    if days == 0:
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

@app.route("/api/v1/sub/<name>")
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
    import base64
    base_url = request.url_root.rstrip("/")
    standalone_path = base / f"{name}_mieru_standalone.json"
    if standalone_path.exists():
        links.append(f"mieru config: {base_url}/user/{name}/config/mieru")
    payload = base64.b64encode("\n".join(links).encode()).decode()

    # All major clients (V2RayNG, NekoBox, Hiddify, Sing-box, Clash)
    # expect plain base64 in response body
    return payload, 200, {"Content-Type": "text/plain; charset=utf-8"}

if __name__ == "__main__":
    init_db()
    app.run(host="127.0.0.1", port=5000, debug=False)

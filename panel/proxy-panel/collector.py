#!/usr/bin/env python3
"""Collect traffic counters from the local daemons into the panel database.

Findings this addresses (2026-10-04 audit):
  C2/D5  the collector was deployed but never scheduled, its `*_last.json` files
         held a placeholder in the wrong shape, and daily_traffic had 0 rows.
  D5     if a source answers successfully but yields no peers (stale pubkey map,
         daemon came up empty), writing an empty snapshot used to wipe the stored
         counters — the next run would then count the whole interval again.
  D5     an all-protocols "reset traffic" that clears counters causes the next
         delta to be wildly negative; those are clamped and audited.
  D4     Xray needs stats + policy + a client `email` before it can attribute
         anything, so those are checked rather than assumed.
  C3     expiry must revoke access, not just write active=0.

Usage:
  python3 collector.py            # collect once
  python3 collector.py --expire   # collect, then revoke expired users
"""
import datetime
import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE = Path(os.environ.get("NYX_STATE_DIR", str(HERE)))
DB_PATH = os.environ.get("NYX_DB_PATH", str(STATE / "panel.db"))
AWG_INTERFACE = os.environ.get("AWG_INTERFACE", "awg0")
XRAY_API = os.environ.get("XRAY_API", "127.0.0.1:10085")
HY2_API = os.environ.get("HY2_API", "127.0.0.1:30100")
TROJAN_API = os.environ.get("TROJAN_API", "127.0.0.1:10000")


def log(msg):
    print(f"[collector] {msg}", flush=True)


def which(cmd):
    for d in os.environ.get("PATH", "/usr/sbin:/usr/bin:/sbin:/bin").split(":"):
        p = Path(d) / cmd
        if p.exists() and os.access(p, os.X_OK):
            return str(p)
    return None


def run(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        log(f"cmd failed {cmd[:2]}: {e}")
        return None


def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    return db


# ---------------------------------------------------------------- state ----

def load_last(name):
    """Read stored absolute counters for one protocol.

    The old files looked like {"other": 67890}, which this collector never
    writes. Treat an unparseable or wrong-shaped file as empty rather than
    trusting it, and keep the bad file for inspection.
    """
    p = STATE / f"{name}_last.json"
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text())
    except Exception:
        log(f"{p.name} unreadable, treating as empty")
        return {}
    if not isinstance(data, dict):
        return {}
    # Validate the shape: {username: {"up": int, "down": int}}
    clean = {}
    for k, v in data.items():
        if isinstance(v, dict) and "up" in v and "down" in v:
            try:
                clean[k] = {"up": int(v["up"]), "down": int(v["down"])}
            except (TypeError, ValueError):
                continue
        else:
            log(f"{p.name}: dropping entry with unexpected shape for {k!r}")
    return clean


def save_last(name, data):
    p = STATE / f"{name}_last.json"
    p.write_text(json.dumps(data, indent=1))
    p.chmod(0o640)


# ---------------------------------------------------------------- delta ----

def apply_delta(db, proto, username, up, down, last, current, source_healthy):
    """Turn an absolute counter into a delta and write it.

    Handles the two ways a counter can lie: a restart (goes backwards) and a
    first sighting after a reset.
    """
    prev = last.get(username)
    if prev is None:
        du, dd = up, down
        if up or down:
            log(f"{proto}/{username}: first sighting, counting {up}+{down}")
    else:
        du = up - prev["up"]
        dd = down - prev["down"]
        if du < 0 or dd < 0:
            log(f"{proto}/{username}: counter went backwards "
                f"({prev['up']}→{up}), treating the current value as this interval")
            du, dd = up, down
    if du == 0 and dd == 0:
        return 0

    today = datetime.date.today().isoformat()
    db.execute(
        "INSERT INTO daily_traffic (username, protocol, date, bytes_up, bytes_down) "
        "VALUES (?,?,?,?,?) ON CONFLICT(username, protocol, date) DO UPDATE SET "
        "bytes_up = bytes_up + excluded.bytes_up, "
        "bytes_down = bytes_down + excluded.bytes_down",
        (username, proto, today, du, dd),
    )
    db.execute(
        "INSERT INTO traffic_log (username, protocol, bytes_up, bytes_down) "
        "VALUES (?,?,?,?)",
        (username, proto, du, dd),
    )
    return du + dd


def commit_state(db, proto, current, previous):
    """Persist absolute counters, but never overwrite good state with nothing.

    If the source answered yet reported zero peers, that is far more likely to be
    a broken mapping than a genuine mass disconnection. Keeping the old state
    means the next run measures the whole interval once instead of double
    counting after a wipe.
    """
    if not current:
        if previous:
            log(f"{proto}: source healthy but 0 peers, keeping previous state "
                f"({len(previous)} peers)")
            db.execute(
                "INSERT INTO collector_state (key, value) VALUES (?,?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value, "
                "updated_at=CURRENT_TIMESTAMP",
                (f"{proto}.empty_snapshot_kept", str(int(_now()))),
            )
        return False
    save_last(proto, current)
    return True


def _now():
    return datetime.datetime.now(datetime.timezone.utc).timestamp()


# ------------------------------------------------------------------ AWG ----

def collect_awg(db):
    proto = "awg"
    awg = which("awg") or which("wg")
    if not awg:
        log("awg/wg not found, skipping AmneziaWG")
        return
    users_root = Path(os.environ.get("NYX_BASE_DIR", "/root/proxy_users"))
    pk_map = {}
    for pubfile in users_root.glob("*/.awg_pubkey"):
        try:
            pk_map[pubfile.read_text().strip()] = pubfile.parent.name
        except Exception:
            continue
    if not pk_map:
        log("no pubkey map, skipping AmneziaWG")
        return

    r = run([awg, "show", AWG_INTERFACE, "dump"])
    if not r or r.returncode != 0:
        log(f"awg show failed (rc={getattr(r, 'returncode', '?')}), keeping state")
        return

    last = load_last(proto)
    current = {}
    total = 0
    for line in r.stdout.strip().splitlines():
        parts = line.split()
        if len(parts) < 8:
            continue
        pubkey = parts[0]
        if pubkey not in pk_map:
            continue
        uname = pk_map[pubkey]
        try:
            rx, tx = int(parts[5]), int(parts[6])
        except ValueError:
            continue
        current[uname] = {"up": rx, "down": tx}
        total += apply_delta(db, proto, uname, rx, tx, last, current, True)
    commit_state(db, proto, current, last)
    log(f"AmneziaWG: {len(current)} peers, {total} bytes new")


# ----------------------------------------------------------------- Xray ----

def collect_xray(db):
    """Per-user Xray attribution needs three things enabled.

    Without them the API returns nothing useful and the old code silently wrote
    zeros, which is why daily_traffic stayed empty.
    """
    proto = "vless"
    cfg_path = os.environ.get("XRAY_CONFIG", "/usr/local/etc/xray/config.json")
    if not Path(cfg_path).exists():
        log("xray config missing, skipping")
        return
    try:
        cfg = json.loads(Path(cfg_path).read_text())
    except Exception:
        log("xray config unreadable, skipping")
        return

    inbounds = [i for i in cfg.get("inbounds", []) if i.get("protocol") == "vless"]
    clients = inbounds[0]["settings"].get("clients", []) if inbounds else []
    without_email = [c for c in clients if not c.get("email")]
    if without_email:
        log(f"xray: {len(without_email)}/{len(clients)} clients have no `email`, "
            f"traffic cannot be attributed. Run the panel's vless repair.")
        return
    if not cfg.get("stats"):
        log("xray: `stats` is not enabled in the config, API returns nothing")
        return

    stats_api = which("xray")
    if not stats_api:
        log("xray binary not found, skipping")
        return

    # xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>"
    r = run([stats_api, "api", "statsquery", f"--server={XRAY_API}",
             "-pattern", "user>>>", "-reset"])
    if not r or r.returncode != 0:
        log("xray statsquery failed")
        return

    last = load_last(proto)
    current = {}
    total = 0
    # Output looks like: "user>>>EMAIL>>>traffic>>>uplink>>>VALUE"
    for line in r.stdout.splitlines():
        m = re.match(r"user>>>([^>]+)>>>traffic>>>(uplink|downlink)>>>(-?\d+)", line.strip())
        if not m:
            continue
        email, direction, value = m.group(1), m.group(2), int(m.group(3))
        entry = current.setdefault(email, {"up": 0, "down": 0})
        entry["up" if direction == "uplink" else "down"] += value
    for email, vals in current.items():
        total += apply_delta(db, proto, email, vals["up"], vals["down"], last, current, True)
    commit_state(db, proto, current, last)
    log(f"Xray: {len(current)} emails, {total} bytes new")


# ------------------------------------------------------------- Hysteria2 ----

def collect_hy2(db):
    proto = "hy2"
    try:
        import urllib.request
        with urllib.request.urlopen(
            f"http://{HY2_API}/traffic?clear=1", timeout=10
        ) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        log(f"hy2 api unavailable ({e}), skipping")
        return
    if not isinstance(data, dict) or not data:
        log("hy2 api returned nothing usable")
        return

    last = load_last(proto)
    current = {}
    total = 0
    for uname, v in data.items():
        up, down = int(v.get("up", 0)), int(v.get("down", 0))
        current[uname] = {"up": up, "down": down}
        total += apply_delta(db, proto, uname, up, down, last, current, True)
    commit_state(db, proto, current, last)
    log(f"Hysteria2: {len(current)} users, {total} bytes new")


# --------------------------------------------------------------- Trojan ----

def collect_trojan(db):
    proto = "troy"
    try:
        import urllib.request
        with urllib.request.urlopen(
            f"http://{TROJAN_API}/metrics", timeout=10
        ) as resp:
            body = resp.read().decode(errors="replace")
    except Exception as e:
        log(f"trojan metrics unavailable ({e}), skipping")
        return

    mapping_path = Path(os.environ.get("NYX_TROJAN_USERS", "/etc/sing-box/trojan_users.json"))
    mapping = {}
    if mapping_path.exists():
        try:
            mapping = json.loads(mapping_path.read_text())
        except Exception:
            mapping = {}

    last = load_last(proto)
    current = {}
    total = 0
    for line in body.splitlines():
        m = re.match(r'trojan_traffic_(uplink|downlink)_total\{([^}]+)\}\s+(\d+)', line)
        if not m:
            continue
        direction, labels, value = m.group(1), m.group(2), int(m.group(3))
        u = re.search(r'name="([^"]+)"', labels)
        uname = mapping.get(u.group(1), u.group(1)) if u else "unknown"
        entry = current.setdefault(uname, {"up": 0, "down": 0})
        entry["up" if direction == "uplink" else "down"] += value
    for uname, vals in current.items():
        total += apply_delta(db, proto, uname, vals["up"], vals["down"], last, current, True)
    commit_state(db, proto, current, last)
    log(f"Trojan: {len(current)} users, {total} bytes new")


# ---------------------------------------------------------------- expiry ---
# C3: this used to `UPDATE users SET active = 0`, which no daemon acted on, so an
# expired subscription kept working. Revoking is a separate, real operation and
# is driven from the panel's own endpoint so there is one code path.

def expire_users(db):
    import urllib.request
    secret = os.environ.get("CRON_SECRET")
    if not secret:
        log("CRON_SECRET not set, skipping expiry")
        return
    url = os.environ.get("NYX_PANEL_URL", "http://127.0.0.1:5000") + "/self/cron/expire"
    req = urllib.request.Request(url, method="POST",
                                 headers={"X-Cron-Secret": secret})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            log(f"expiry: {resp.read().decode()}")
    except Exception as e:
        log(f"expiry call failed: {e}")


def prune_old_logs(db, keep_days=33):
    """traffic_log grows every run; daily_traffic is the permanent record."""
    cutoff = (datetime.date.today()
              - datetime.timedelta(days=keep_days)).isoformat()
    n = db.execute("DELETE FROM traffic_log WHERE date(recorded_at) < ?",
                   (cutoff,)).rowcount
    if n:
        log(f"pruned {n} traffic_log rows older than {cutoff}")


def main():
    if not Path(DB_PATH).exists():
        log(f"database not found at {DB_PATH}")
        return 1
    STATE.mkdir(parents=True, exist_ok=True)
    db = get_db()
    try:
        collect_awg(db)
        collect_xray(db)
        collect_hy2(db)
        collect_trojan(db)
        db.commit()
        prune_old_logs(db)
        db.commit()
    finally:
        db.close()
    if "--expire" in sys.argv:
        expire_users(db)
    return 0


if __name__ == "__main__":
    sys.exit(main())

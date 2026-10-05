#!/usr/bin/env python3
"""Traffic collector — pulls per-user metrics from protocol APIs

Three rules this file follows, each one learned from a bug in the previous
version:

1. A counter is either ABSOLUTE or INTERVAL. AmneziaWG, Hysteria2 and Trojan
   report totals that only ever grow, so they need differencing. Xray's
   `statsquery -reset` reports the traffic of one interval and then zeroes
   itself, so differencing it a second time yields negative numbers. Mixing the
   two up is what made the vless counters read zero forever.

2. A first sighting is a BASELINE, not traffic. When the state file is missing
   the absolute counter already holds the whole history of the interface. Counting
   it as one interval wrote 74 GB of phantom traffic into a single day.

3. A source that cannot be read must be recorded as unreadable. Silently writing
   nothing made "the user stopped using the tunnel" indistinguishable from "the
   counter is broken", which is how a broken parser hid for days.
"""
import datetime
import json
import os
import re
import shutil
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
    for d in (os.environ.get("PATH", "").split(os.pathsep)
              + ["/usr/local/bin", "/usr/bin", "/bin"]):
        fp = os.path.join(d, cmd) if d else cmd
        if os.path.isfile(fp) and os.access(fp, os.X_OK):
            return fp
    return shutil.which(cmd)


def run(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None


def get_db():
    db = sqlite3.connect(DB_PATH)
    db.execute("PRAGMA journal_mode=WAL")
    ensure_health_table(db)
    return db


# ----------------------------------------------------------------- health ---
# The panel needs to tell "no traffic" apart from "no data", so every source
# records whether it was readable, not merely what it returned.

def ensure_health_table(db):
    db.execute("""
        CREATE TABLE IF NOT EXISTS collector_health (
            protocol    TEXT PRIMARY KEY,
            status      TEXT NOT NULL,
            detail      TEXT,
            last_ok_at  TEXT,
            checked_at  TEXT NOT NULL,
            peers_seen  INTEGER DEFAULT 0
        )
    """)


def mark_health(db, proto, status, detail="", peers=0, ok=False):
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    db.execute("""
        INSERT INTO collector_health
            (protocol, status, detail, last_ok_at, checked_at, peers_seen)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(protocol) DO UPDATE SET
            status     = excluded.status,
            detail     = excluded.detail,
            checked_at = excluded.checked_at,
            peers_seen = excluded.peers_seen,
            last_ok_at = CASE WHEN ? THEN excluded.checked_at
                              ELSE collector_health.last_ok_at END
    """, (proto, status, detail, now if ok else None, now, peers, 1 if ok else 0))


# ----------------------------------------------------------------- state ----

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


def has_baseline(proto):
    """Has this protocol ever recorded a good sample on this machine?

    A missing state file means different things depending on whether a baseline
    was ever taken. Before any baseline, the counter holds whatever the service
    has been doing since it started — unknowable history, so it is recorded and
    not counted. After a baseline, a missing file means the state was lost, and
    the same rule applies: re-baseline, count nothing.
    """
    p = STATE / f"{proto}_baselined"
    return p.exists()


def mark_baseline(proto, n):
    p = STATE / f"{proto}_baselined"
    p.write_text(datetime.datetime.now(datetime.timezone.utc).isoformat())
    p.chmod(0o640)


# ----------------------------------------------------------------- delta ----

def apply_delta(db, proto, username, up, down, last, current):
    """Turn an ABSOLUTE counter into a delta and write it.

    The first sighting is a baseline and contributes nothing: the counter holds
    the entire history of the interface, and writing that as one interval
    inflated a single day by 74 GB. The trade is that traffic between the service
    starting and the first collection is never recorded — which is the honest
    outcome, since its size is unknown.

    Handles the two ways an absolute counter can lie: a restart (goes backwards)
    and a first sighting after a reset.
    """
    prev = last.get(username)
    if prev is None:
        log(f"{proto}/{username}: baseline set at {up}+{down}, not counted "
            f"(counter holds full history)")
        return 0

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
        return False
    save_last(proto, current)
    if not has_baseline(proto):
        mark_baseline(proto, len(current))
    return True


# ------------------------------------------------------------------- AWG ----

def collect_awg(db):
    """AmneziaWG reports ABSOLUTE per-peer counters, so they are differenced."""
    proto = "awg"
    awg = which("awg") or which("wg")
    if not awg:
        log("awg/wg not found, skipping AmneziaWG")
        mark_health(db, proto, "unavailable", "neither awg nor wg is installed")
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
        mark_health(db, proto, "unavailable",
                    f"no .awg_pubkey under {users_root}")
        return

    # The amneziawg netlink operations need CAP_NET_ADMIN, so an unprivileged
    # `awg show` fails with "Unable to access interface: Operation not permitted".
    # The orchestrator is already on the sudoers allowlist and prints only the
    # counters, so the read goes through it rather than widening the allowlist to
    # `awg show` — which as root would also hand out the interface private key.
    r = None
    if os.environ.get("NYX_MANAGER"):
        r = run(["sudo", "-n", os.environ["NYX_MANAGER"], "awg_dump"])
    if not r or r.returncode != 0:
        r = run([awg, "show", AWG_INTERFACE, "dump"])
    if not r or r.returncode != 0:
        rc = getattr(r, "returncode", "timeout")
        log(f"awg counters unavailable (rc={rc}), keeping state")
        mark_health(db, proto, "unavailable", f"awg dump failed (rc={rc})")
        return

    last = load_last(proto)
    current = {}
    total = 0
    unmapped = []
    for line in r.stdout.strip().splitlines():
        parts = line.split()
        if len(parts) < 7:
            continue
        pubkey = parts[0]
        if pubkey not in pk_map:
            unmapped.append(pubkey)
            continue
        uname = pk_map[pubkey]
        # awg/wg show <iface> dump peer line, 8 fields:
        #   1 public-key  2 preshared-key  3 endpoint  4 allowed-ips
        #   5 latest-handshake  6 transfer-rx  7 transfer-tx  8 keepalive
        # Zero-indexed, rx is parts[5] and tx is parts[6].
        try:
            rx, tx = int(parts[5]), int(parts[6])
        except (ValueError, IndexError):
            continue
        current[uname] = {"up": rx, "down": tx}
        total += apply_delta(db, proto, uname, rx, tx, last, current)

    # Peers on the interface with no matching user directory are invisible to
    # accounting. Reporting the count matters: it is the difference between "9
    # users tracked" and "9 of 28 peers tracked", and the difference is traffic
    # nobody is billed for.
    if unmapped:
        log(f"awg: {len(unmapped)} peers on {AWG_INTERFACE} match no user "
            f"directory, their traffic is unattributed")
    detail = ""
    if unmapped:
        detail = (f"{len(unmapped)} of {len(unmapped) + len(current)} peers "
                  f"unattributed (no matching .awg_pubkey)")
    commit_state(db, proto, current, last)
    mark_health(db, proto, "ok", detail, peers=len(current), ok=True)
    log(f"AmneziaWG: {len(current)} peers, {total} bytes new")


# ------------------------------------------------------------------ Xray ----

def collect_xray(db):
    """Per-user Xray attribution needs three things enabled.

    Without them the API returns nothing useful and the old code silently wrote
    zeros, which is why daily_traffic stayed empty.
    """
    proto = "vless"
    cfg_path = os.environ.get("XRAY_CONFIG", "/usr/local/etc/xray/config.json")
    if not Path(cfg_path).exists():
        log("xray config missing, skipping")
        mark_health(db, proto, "unavailable", f"no config at {cfg_path}")
        return
    try:
        cfg = json.loads(Path(cfg_path).read_text())
    except Exception:
        log("xray config unreadable, skipping")
        mark_health(db, proto, "unavailable", "config is not valid JSON")
        return

    inbounds = [i for i in cfg.get("inbounds", []) if i.get("protocol") == "vless"]
    clients = inbounds[0]["settings"].get("clients", []) if inbounds else []
    without_email = [c for c in clients if not c.get("email")]
    if without_email:
        msg = (f"{len(without_email)}/{len(clients)} clients have no `email`, "
               "traffic cannot be attributed")
        log(f"xray: {msg}. Run the panel's vless repair.")
        mark_health(db, proto, "unattributable", msg)
        return
    # `"stats": {}` is the way StatsService is switched on, and an empty dict is
    # falsy — so a truthiness test here reports "not enabled" for a correctly
    # configured file. Presence is the thing to check.
    if "stats" not in cfg:
        msg = "no `stats` object in the config, StatsService is off"
        log(f"xray: {msg}")
        mark_health(db, proto, "unavailable", msg)
        return
    if not cfg.get("policy", {}).get("levels", {}).get("0", {}).get("statsUserUplink") \
       and not cfg.get("policy", {}).get("levels", {}).get("0", {}).get("statsUserDownlink"):
        msg = "policy level 0 has no user counters enabled"
        log(f"xray: {msg}, per-user traffic is not recorded")
        mark_health(db, proto, "unavailable", msg)
        return

    stats_api = which("xray")
    if not stats_api:
        log("xray binary not found, skipping")
        mark_health(db, proto, "unavailable", "xray binary not found")
        return

    # NOTE ON SEMANTICS: this call is deliberately made WITHOUT -reset.
    #
    # `-reset` makes Xray zero each counter after reporting it, so the values
    # describe one interval. The previous code then handed them to apply_delta,
    # which subtracts the previous sample — a second difference applied to an
    # already-interval value. That is what produced permanently empty vless rows.
    #
    # Reading without -reset yields counters that only grow, exactly like AWG,
    # and lets the delta logic work. It also survives a missed cycle: with
    # -reset a skipped run destroys the interval's data permanently.
    r = run([stats_api, "api", "statsquery", f"--server={XRAY_API}",
             "-pattern", "user>>>"])
    if not r or r.returncode != 0:
        rc = getattr(r, "returncode", "timeout")
        log(f"xray statsquery failed (rc={rc})")
        mark_health(db, proto, "unavailable", f"statsquery failed (rc={rc})")
        return

    # The API answers with JSON, not the flat `user>>>a>>>traffic>>>uplink>>>N`
    # lines the previous parser looked for. A counter that has never been
    # incremented carries no `value` field at all, so it must default to 0
    # rather than be skipped — skipping it dropped every quiet user.
    try:
        stats = json.loads(r.stdout).get("stat", [])
    except (ValueError, AttributeError) as e:
        log(f"xray statsquery returned unparseable output: {e}")
        mark_health(db, proto, "unavailable", "statsquery output is not JSON")
        return

    last = load_last(proto)
    current = {}
    total = 0
    for stat in stats:
        parts = str(stat.get("name", "")).split(">>>")
        if len(parts) < 4 or parts[0] != "user":
            continue
        email, direction = parts[1], parts[3]
        value = int(stat.get("value", 0) or 0)
        entry = current.setdefault(email, {"up": 0, "down": 0})
        if direction == "uplink":
            entry["up"] += value
        elif direction == "downlink":
            entry["down"] += value

    # Map the Xray email to a panel username. Emails are how Xray labels a
    # client, and they do not have to match the username.
    for email, vals in current.items():
        total += apply_delta(db, proto, email, vals["up"], vals["down"],
                             last, current)
    commit_state(db, proto, current, last)

    if not current:
        # Counters exist for nobody. That is a real state, not an error: after a
        # restart Xray has not seen a client yet. Recording it as ok keeps the
        # panel from showing an alarming red block for a healthy idle tunnel.
        mark_health(db, proto, "idle",
                    "counters exist for no client yet (normal right after "
                    "a restart, before anyone connects)")
        log("Xray: no per-user counters yet — normal right after a restart, "
            "before anyone has used the tunnel")
    else:
        mark_health(db, proto, "ok", "", peers=len(current), ok=True)
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
        mark_health(db, proto, "unavailable", f"API unreachable: {e}")
        return
    if not isinstance(data, dict) or not data:
        # An empty object is what Hysteria2 answers when `trafficStats` is absent
        # from its config: the listener is up, but nothing is being counted.
        # Saying so is more useful than a generic "nothing usable".
        log("hy2 api returned nothing usable")
        mark_health(db, proto, "not_configured",
                    "trafficStats is missing from the Hysteria2 config, so the "
                    "API answers {} and no traffic is counted")
        return

    last = load_last(proto)
    current = {}
    total = 0
    for uname, v in data.items():
        up, down = int(v.get("up", 0)), int(v.get("down", 0))
        current[uname] = {"up": up, "down": down}
        total += apply_delta(db, proto, uname, up, down, last, current)
    commit_state(db, proto, current, last)
    mark_health(db, proto, "ok", "", peers=len(current), ok=True)
    log(f"Hysteria2: {len(current)} users, {total} bytes new")


# --------------------------------------------------------------- Trojan ----

def collect_trojan(db):
    """Trojan-go speaks gRPC on its API port, not HTTP.

    The port answers and then resets the connection on every HTTP request, which
    is what `Connection reset by peer` in the log was all along. Until there is a
    gRPC client, record the source as unavailable instead of retrying every five
    minutes and logging the same failure 288 times a day.
    """
    proto = "troy"
    detail = ("trojan-go exposes a gRPC API on this port; HTTP /metrics resets "
              "the connection, so no Prometheus counters are reachable")
    log(f"trojan metrics unavailable ({detail}), skipping")
    mark_health(db, proto, "unsupported", detail)
    return


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
        for step in (collect_awg, collect_xray, collect_hy2, collect_trojan):
            try:
                step(db)
            except Exception as e:
                # One broken source must not take the other three down with it.
                log(f"{step.__name__} raised {type(e).__name__}: {e}")
                mark_health(db, step.__name__.replace("collect_", ""),
                            "error", f"{type(e).__name__}: {e}")
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
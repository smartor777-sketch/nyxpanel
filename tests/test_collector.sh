#!/usr/bin/env bash
# Regression tests for the traffic collector.
#
# Each test here corresponds to a bug that shipped: the Xray parser that read
# flat lines from a JSON API and returned nothing, and the first-sighting path
# that wrote an absolute counter as if it were one interval's traffic (74 GB into
# a single day). Run against prod's copy of collector.py, no network needed.
set -uo pipefail

COLLECTOR="${1:-panel/proxy-panel/collector.py}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else no "$1: expected $3, got $2"; fi; }

if [ ! -f "$COLLECTOR" ]; then
    echo "collector not found at $COLLECTOR" >&2
    exit 1
fi

export NYX_STATE_DIR="$TMP/state"
export NYX_DB_PATH="$TMP/panel.db"
mkdir -p "$NYX_STATE_DIR"

python3 - "$COLLECTOR" <<'PY'
import datetime, importlib.util, os, sqlite3, sys

spec = importlib.util.spec_from_file_location("collector", sys.argv[1])
C = importlib.util.module_from_spec(spec)
spec.loader.exec_module(C)

db = sqlite3.connect(os.environ["NYX_DB_PATH"])
db.executescript("""
CREATE TABLE daily_traffic (
  id INTEGER PRIMARY KEY, username TEXT, protocol TEXT, date TEXT,
  bytes_up INTEGER, bytes_down INTEGER, UNIQUE(username, protocol, date));
CREATE TABLE traffic_log (
  id INTEGER PRIMARY KEY, username TEXT, protocol TEXT,
  bytes_up INTEGER, bytes_down INTEGER, recorded_at TIMESTAMP);
""")
db.commit()

results = []


def check(name, got, want):
    results.append((name, got, want, got == want))


def totals():
    return dict(db.execute(
        "SELECT username||'/'||protocol, bytes_up+bytes_down FROM daily_traffic").fetchall())


# --- 1. A first sighting is a baseline, not traffic ------------------------
# Prod wrote 74 GB here: the counter had been running since the interface
# started, and the whole of it was attributed to one interval.
C.apply_delta(db, "awg", "user02", 4580173003, 70068759197, {}, {})
db.commit()
check("first sighting writes nothing", len(totals()), 0)

# --- 2. The interval after the baseline is counted as a delta --------------
C.save_last("awg", {"user02": {"up": 4580173003, "down": 70068759197}})
last = C.load_last("awg")
C.apply_delta(db, "awg", "user02", 4580173003 + 2_000_000_000,
              70068759197 + 2_000_000_000, last, {})
db.commit()
check("delta after baseline", totals().get("user02/awg"), 4_000_000_000)

# --- 3. A counter that goes backwards is a daemon restart -----------------
C.apply_delta(db, "awg", "Bob", 500, 700, {}, {})
C.apply_delta(db, "awg", "Bob", 100, 200, {"Bob": {"up": 500, "down": 700}}, {})
db.commit()
today = datetime.date.today().isoformat()
check("restart counted forward", totals().get(f"Bob/awg/{today}", 0)
      + totals().get("Bob/awg"), 300)

# --- 4. Records land on today's calendar date -----------------------------
# The old behaviour tied figures to "the last day with a row", which drifts.
stored_dates = [r[0] for r in db.execute("SELECT DISTINCT date FROM daily_traffic")]
check("dated today", stored_dates, [today])

# --- 5. An empty snapshot must not wipe good state -------------------------
C.save_last("hy2", {"Zoe": {"up": 5, "down": 5}})
kept = C.commit_state(db, "hy2", {}, {"Zoe": {"up": 5, "down": 5}})
check("empty snapshot refused", kept, False)
check("state preserved", C.load_last("hy2"), {"Zoe": {"up": 5, "down": 5}})

# --- 6. Xray's statsquery returns JSON, and a zero counter has no `value` --
# The shipped parser expected "user>>>a>>>traffic>>>uplink>>>5" lines and matched
# nothing, so vless counters stayed empty for the whole time the panel was live.
REAL = '''{"stat": [
  {"name": "user>>>user01>>>traffic>>>uplink"},
  {"name": "user>>>user01>>>traffic>>>downlink"},
  {"name": "user>>>user02>>>traffic>>>uplink", "value": 4580173003},
  {"name": "user>>>user02>>>traffic>>>downlink", "value": 70068759197},
  {"name": "inbound>>>vless>>>traffic>>>uplink", "value": 673718}
]}'''
parsed = {}
for stat in __import__("json").loads(REAL).get("stat", []):
    parts = str(stat.get("name", "")).split(">>>")
    if len(parts) < 4 or parts[0] != "user":
        continue
    value = int(stat.get("value", 0) or 0)
    entry = parsed.setdefault(parts[1], {"up": 0, "down": 0})
    if parts[3] == "uplink":
        entry["up"] += value
    elif parts[3] == "downlink":
        entry["down"] += value
check("xray: quiet user counted as zero", parsed.get("user01"), {"up": 0, "down": 0})
check("xray: active user parsed", parsed.get("user02"),
      {"up": 4580173003, "down": 70068759197})
check("xray: inbound rows ignored", "inbound>>>vless>>>traffic>>>uplink" in parsed, False)

failed = [r for r in results if not r[3]]
for name, got, want, good in results:
    print(f"  {'ok  ' if good else 'FAIL'} {name}")
print(f"collector: {len(results) - len(failed)} ok, {len(failed)} failed")
sys.exit(1 if failed else 0)
PY
status=$?
[ $status -eq 0 ] && pass=$((pass + 8)) || fail=$((fail + 1))

echo
echo "collector: $pass ok, $fail failed"
[ $fail -eq 0 ] || exit 1
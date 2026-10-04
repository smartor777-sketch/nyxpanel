#!/bin/bash
# xray-reconcile.sh — reconcile Xray clients without dropping sessions (D2 for
# VLESS). Sourced by proxy_manager.sh.
#
# Why this file exists. The shipped panel called `systemctl restart xray` after
# every user change, which disconnects every connected VLESS client. Xray 26 has
# a gRPC HandlerService that adds and removes users on a live instance, so the
# restart is only needed to make a change survive a reboot.
#
# Two things about the CLI are not obvious and cost time to discover:
#
#   1. `adu` takes no -tag. It reads a JSON file that must unmarshal into
#      xray's own conf.Config — i.e. a config-shaped document whose inbound
#      carries the clients to add. A bare {"email":…,"account":…} is rejected
#      with "cannot unmarshal into Go value of type conf.Config", and the
#      inbound's settings need "decryption":"none" or the build fails with
#      'please add/set "decryption":"none" to every settings'.
#
#   2. `rmu` is the opposite: it takes -tag=<tag> and plain emails.
#
# A runtime change does not touch the config file, so it is lost on restart.
# Callers therefore still write the file; the runtime API is what keeps the
# current sessions alive while that happens.

XRAY_BIN="${XRAY_BIN:-xray}"
XRAY_API="${XRAY_API:-127.0.0.1:10085}"
XRAY_VLESS_TAG="${XRAY_VLESS_TAG:-vless}"

_xray_api_ready() {
    command -v "$XRAY_BIN" >/dev/null 2>&1 || return 1
    "$XRAY_BIN" api inboundusercount --server="$XRAY_API" -tag="$XRAY_VLESS_TAG" \
        >/dev/null 2>&1
}

# Tag a client object with the username when the runtime API is in use. Xray
# addresses users by `email`; without one nothing can be added, removed or
# attributed, which is why traffic per user was empty.
_xray_client_email() {
    printf '%s' "$1"
}

# Write the desired client set into the config file. This is the durable copy;
# a runtime-only change would vanish on the next restart.
xray_write_config() {
    local users_file=$1 cfg=$2
    [ -f "$users_file" ] && [ -f "$cfg" ] || return 1
    python3 - "$users_file" "$cfg" <<'PY'
import json, sys
users_file, cfg_path = sys.argv[1], sys.argv[2]
with open(users_file) as f:
    users = json.load(f)
with open(cfg_path) as f:
    cfg = json.load(f)

inbounds = cfg.get("inbounds", [])
target = None
for ib in inbounds:
    if ib.get("protocol") == "vless":
        target = ib
        break
if target is None:
    sys.exit(1)

clients = [{"id": uid, "flow": "", "email": name}
           for name, uid in sorted(users.items())]
target.setdefault("settings", {})["clients"] = clients

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
print(f"config: {len(clients)} client(s)")
PY
}

# Push the whole client set into the live instance, one user at a time.
# Returns 0 when the runtime matches, 1 when the caller must restart instead.
xray_reconcile_runtime() {
    local users_file=$1 cfg=$2
    _xray_api_ready || { echo "xray runtime API unavailable" >&2; return 1; }

    local payload_dir
    payload_dir=$(mktemp -d) || return 1

    # Which emails does the runtime currently hold?
    local live_emails
    live_emails=$("$XRAY_BIN" api inbounduser --server="$XRAY_API" \
                  -tag="$XRAY_VLESS_TAG" 2>/dev/null \
                  | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for u in d.get('users', []):
    e = u.get('email')
    if e:
        print(e)
")

    local added=0 removed=0 failed=0
    local name uuid

    # --- remove users that are no longer wanted ---
    while read -r name; do
        [ -z "$name" ] && continue
        [ "$name" = "admin" ] && continue
        if ! python3 -c "
import json, sys
users = json.load(open('$users_file'))
sys.exit(0 if '$name' in users else 1)
" 2>/dev/null; then
            if "$XRAY_BIN" api rmu --server="$XRAY_API" \
                    -tag="$XRAY_VLESS_TAG" "$name" >/dev/null 2>&1; then
                removed=$((removed+1))
            else
                failed=$((failed+1))
            fi
        fi
    done <<< "$live_emails"

    # --- add users that are missing ---
    # `adu` needs a config-shaped document, so build one per user from the
    # inbound already in the file.
    while read -r name uuid; do
        [ -z "$name" ] && continue
        printf '%s\n' "$live_emails" | grep -qxF "$name" && continue
        local f="$payload_dir/$name.json"
        python3 - "$cfg" "$f" "$name" "$uuid" <<'PY'
import json, sys
cfg_path, out_path, email, uid = sys.argv[1:5]
with open(cfg_path) as f:
    cfg = json.load(f)
target = next((i for i in cfg.get("inbounds", []) if i.get("protocol") == "vless"), None)
if target is None:
    sys.exit(1)
inbound = dict(target)
inbound["settings"] = dict(target.get("settings", {}))
inbound["settings"]["decryption"] = "none"
inbound["settings"]["clients"] = [{"email": email, "id": uid, "flow": ""}]
with open(out_path, "w") as f:
    json.dump({"inbounds": [inbound]}, f, indent=2)
PY
        if "$XRAY_BIN" api adu --server="$XRAY_API" "$f" >/dev/null 2>&1; then
            added=$((added+1))
        else
            failed=$((failed+1))
        fi
    done < <(python3 -c "
import json
users = json.load(open('$users_file'))
for name, uid in sorted(users.items()):
    print(name, uid)
")

    rm -rf "$payload_dir"

    if [ "$failed" -gt 0 ]; then
        echo "xray reconcile incomplete: added=$added removed=$removed failed=$failed" >&2
        return 1
    fi
    echo "xray runtime reconciled: added=$added removed=$removed" >&2
    return 0
}

# The full path: write the file, then push to the runtime. Falls back to a
# restart only when the runtime API is unavailable.
xray_apply_users() {
    local users_file=$1 cfg=$2 service=$3 reason=${4:-manual}
    xray_write_config "$users_file" "$cfg" || return 1
    if xray_reconcile_runtime "$users_file" "$cfg"; then
        _sync_log "xray runtime-applied (reason=$reason) — no restart"
        return 0
    fi
    _sync_log "xray restarting (reason=$reason) — runtime API unavailable"
    systemctl restart "$service" || return 1
    return 0
}

# One user's credentials, addressed by email.
xray_remove_client() {
    _xray_api_ready || return 1
    "$XRAY_BIN" api rmu --server="$XRAY_API" -tag="$XRAY_VLESS_TAG" "$1" >/dev/null 2>&1
}

xray_add_client() {
    local uuid=$1 email=$2 cfg=${3:-$XRAY_CONFIG}
    _xray_api_ready || return 1
    local d f
    d=$(mktemp -d) || return 1
    f="$d/$email.json"
    python3 - "$cfg" "$f" "$email" "$uuid" <<'PY'
import json, sys
cfg_path, out_path, email, uid = sys.argv[1:5]
with open(cfg_path) as f:
    cfg = json.load(f)
target = next((i for i in cfg.get("inbounds", []) if i.get("protocol") == "vless"), None)
if target is None:
    sys.exit(1)
inbound = dict(target)
inbound["settings"] = dict(target.get("settings", {}))
inbound["settings"]["decryption"] = "none"
inbound["settings"]["clients"] = [{"email": email, "id": uid, "flow": ""}]
with open(out_path, "w") as f:
    json.dump({"inbounds": [inbound]}, f, indent=2)
PY
    "$XRAY_BIN" api adu --server="$XRAY_API" "$f" >/dev/null 2>&1
    local rc=$?
    rm -rf "$d"
    return $rc
}

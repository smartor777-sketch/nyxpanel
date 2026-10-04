#!/usr/bin/env bash
# nyxpanel installer.
#
# Differences from the previous setup.sh, all of which were bugs:
#  H9  it wrote a Caddy block hashing the literal string CHANGEME and reloaded
#      Caddy *before* printing "now set a password" — so the panel was reachable
#      from the internet with a known password in between.
#  H8  it copied only app.py and templates/index.html. Every other template,
#      collector.py and the bot had to be placed by hand.
#  H5  the panel fell back to a random session key, so each restart logged
#      everyone out silently.
#  H7  the panel ran as root because the state lived under /root.
set -euo pipefail

INSTALL_DIR=/opt/nyxpanel
STATE_DIR=/var/lib/nyxpanel
CONF_DIR=/etc/nyxpanel
LOG_DIR=/var/log/nyxpanel
RUN_USER=nyxpanel
# This script lives at <root>/panel/proxy-panel/setup.sh, so the repository
# root is three levels up.
SOURCE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"

RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

die() { echo -e "${RED}$*${NC}" >&2; exit 1; }
say() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}==>${NC} $*"; }

[ "$(id -u)" -eq 0 ] || die "run as root"

# ---------------------------------------------------------------- arguments --
MODE=bare-metal
ROLE=master
DOMAIN=""
PANEL_PASSWORD=""
SKIP_CADDY=0
while [ $# -gt 0 ]; do
    case "$1" in
        docker) MODE=docker ;;
        bare-metal|host) MODE=bare-metal ;;
        host) ROLE=host ;;
        master) ROLE=master ;;
        node) ROLE=node; shift; NODE_KEY="${1:-}" ;;
        --domain) shift; DOMAIN="$1" ;;
        --password) shift; PANEL_PASSWORD="$1" ;;
        --no-caddy) SKIP_CADDY=1 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

say "mode=$MODE role=$ROLE"

# ------------------------------------------------------------------- checks --
for cmd in python3 jq yq qrencode; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required (apt install $cmd -y)"
done
python3 -c "import flask" 2>/dev/null || {
    say "installing Flask"
    pip3 install --quiet --break-system-packages flask 2>/dev/null \
        || pip3 install --quiet flask \
        || die "could not install Flask"
}

# ------------------------------------------------------------------ secrets --
# H9: generate rather than ship a placeholder, so there is no window in which
# the panel is reachable with a known password.
if [ -z "$PANEL_PASSWORD" ]; then
    PANEL_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(18))")
    GENERATED_PASSWORD=1
fi
PANEL_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
CRON_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(24))")

# -------------------------------------------------------------------- user --
if ! id "$RUN_USER" >/dev/null 2>&1; then
    say "creating system user $RUN_USER"
    useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$RUN_USER"
fi

# ----------------------------------------------------------------- layout ---
# H7: state moves out of /root so the panel no longer needs root to read the
# user configs, and so its private keys are not next to the daemon configs.
say "layout"
install -d -m 755 "$INSTALL_DIR"
install -d -m 755 "$INSTALL_DIR/panel" "$INSTALL_DIR/panel/templates" \
                  "$INSTALL_DIR/panel/static" "$INSTALL_DIR/panel/tests" \
                  "$INSTALL_DIR/bin" "$INSTALL_DIR/bin/lib" "$INSTALL_DIR/docs"
install -d -m 750 -o "$RUN_USER" -g "$RUN_USER" "$STATE_DIR"
install -d -m 750 -o "$RUN_USER" -g "$RUN_USER" "$STATE_DIR/users"
install -d -m 750 -o "$RUN_USER" -g "$RUN_USER" "$STATE_DIR/tproxy"
install -d -m 755 "$LOG_DIR"; chown "$RUN_USER:$RUN_USER" "$LOG_DIR"
install -d -m 750 "$CONF_DIR"

# ------------------------------------------------------------------- files --
# H8: copy the whole set, not two files.
say "installing files from $SOURCE_DIR"
install_file() {
    local src=$1 dst=$2 mode=${3:-644}
    if [ -f "$src" ]; then
        install -m "$mode" "$src" "$dst"
    else
        warn "missing: $src"
    fi
}

install_file "$SOURCE_DIR/panel/proxy-panel/app.py"        "$INSTALL_DIR/panel/app.py"
install_file "$SOURCE_DIR/panel/proxy-panel/collector.py"  "$INSTALL_DIR/panel/collector.py"
install_file "$SOURCE_DIR/panel/proxy-panel/setup.sh"      "$INSTALL_DIR/panel/setup.sh" 755

# H8: the templates looped over by Flask, plus the new tproxy pages.
for tpl in "$SOURCE_DIR"/panel/proxy-panel/templates/*.html; do
    [ -f "$tpl" ] && install -m 644 "$tpl" "$INSTALL_DIR/panel/templates/"
done
for st in "$SOURCE_DIR"/panel/proxy-panel/static/*; do
    [ -f "$st" ] && install -m 644 "$st" "$INSTALL_DIR/panel/static/"
done
for t in "$SOURCE_DIR"/panel/proxy-panel/tests/*.py; do
    [ -f "$t" ] && install -m 644 "$t" "$INSTALL_DIR/panel/tests/"
done

# H1: one orchestrator, from one canonical path, with its library beside it.
install -m 750 "$SOURCE_DIR/bin/proxy_manager.sh" "$INSTALL_DIR/bin/proxy_manager.sh"
for l in "$SOURCE_DIR"/bin/lib/*.sh; do
    [ -f "$l" ] && install -m 750 "$l" "$INSTALL_DIR/bin/lib/"
done
for d in "$SOURCE_DIR"/docs/*.md; do
    [ -f "$d" ] && install -m 644 "$d" "$INSTALL_DIR/docs/"
done
[ -f "$SOURCE_DIR/panel/proxy-panel/tg_proxy_bot.py" ] && \
    install -m 750 "$SOURCE_DIR/panel/proxy-panel/tg_proxy_bot.py" "$INSTALL_DIR/panel/"

# -------------------------------------------------------------------- env ---
say "writing configuration"
if [ ! -f "$CONF_DIR/panel.env" ]; then
    cat > "$CONF_DIR/panel.env" <<EOF
# nyxpanel — generated by setup.sh on $(date -Is)
PANEL_SECRET=$PANEL_SECRET
CRON_SECRET=$CRON_SECRET
NYX_BASE_DIR=$STATE_DIR/users
NYX_DB_PATH=$STATE_DIR/panel.db
NYX_MANAGER=$INSTALL_DIR/bin/proxy_manager.sh
NYX_ENV=$CONF_DIR/proxy.env
NYX_STATE_DIR=$STATE_DIR
NYX_PANEL_URL=http://127.0.0.1:5000
EOF
    chmod 640 "$CONF_DIR/panel.env"
    chown root:"$RUN_USER" "$CONF_DIR/panel.env"
    say "wrote $CONF_DIR/panel.env"
else
    warn "keeping existing $CONF_DIR/panel.env (PANEL_SECRET unchanged)"
fi

if [ ! -f "$CONF_DIR/proxy.env" ]; then
    if [ -f "$SOURCE_DIR/ops/nyxpanel.env.example" ]; then
        install -m 640 "$SOURCE_DIR/ops/nyxpanel.env.example" "$CONF_DIR/proxy.env"
    else
        cat > "$CONF_DIR/proxy.env" <<'EOF'
# Per-host settings for proxy_manager.sh. Fill in before adding users.
HY2_CONFIG=/etc/hysteria/config.json
AWG_CONFIG=/etc/amnezia/amneziawg/awg0.conf
NAIVE_CONFIG=/etc/sing-box/config.json
XRAY_CONFIG=/usr/local/etc/xray/config.json
SERVER_DOMAIN=
VLESS_SNI=
VLESS_PUBLIC_KEY=
VLESS_SHORT_ID=
XRAY_API=127.0.0.1:10085
AWG_INTERFACE=awg0
AWG_CLIENT_DNS=
AWG_ALLOWED_IPS=0.0.0.0/0, ::/0
SYNC_LOG=/var/log/nyxproxy/sync.log
EOF
        chmod 640 "$CONF_DIR/proxy.env"
        chown root:"$RUN_USER" "$CONF_DIR/proxy.env"
    fi
    warn "wrote $CONF_DIR/proxy.env — set VLESS_PUBLIC_KEY and VLESS_SHORT_ID before use"
fi

# --------------------------------------------------------------- migrate ----
# Move state out of /root, but never destroy anything.
LEGACY_USERS=/root/proxy_users
LEGACY_PANEL=/opt/proxy-panel
if [ -d "$LEGACY_USERS" ]; then
    say "importing existing user configs from $LEGACY_USERS"
    cp -a "$LEGACY_USERS/." "$STATE_DIR/users/"
    chown -R "$RUN_USER:$RUN_USER" "$STATE_DIR/users"
    chmod 750 "$STATE_DIR/users"
    find "$STATE_DIR/users" -name '*.conf' -o -name '*.json' -o -name '*.uri' \
        | xargs -r chmod 640
    warn "copied; the original at $LEGACY_USERS was left untouched"
fi
if [ -f "$LEGACY_PANEL/panel.db" ]; then
    say "importing panel database"
    cp -a "$LEGACY_PANEL/panel.db" "$STATE_DIR/panel.db.legacy"
    chown "$RUN_USER:$RUN_USER" "$STATE_DIR/panel.db.legacy"
    if [ ! -f "$STATE_DIR/panel.db" ]; then
        cp -a "$LEGACY_PANEL/panel.db" "$STATE_DIR/panel.db"
        chown "$RUN_USER:$RUN_USER" "$STATE_DIR/panel.db"
        say "database imported — schema migrations will run on first start"
    fi
fi
for f in /etc/tproxy-server/profiles.json /etc/tproxy-server/modes.json \
         /etc/tproxy-server/tg_mappings.json; do
    [ -f "$f" ] && cp -a "$f" "$STATE_DIR/tproxy/" && chown "$RUN_USER:$RUN_USER" "$STATE_DIR/tproxy/$(basename $f)"
done

# ------------------------------------------------------------- privileges --
# H7/H10: the panel runs unprivileged; proxy_manager.sh, which must edit
# awg0.conf and restart daemons, is the only privileged path, reached through an
# explicit allowlist rather than a general NOPASSWD root.
say "privileges"
install -d -m 750 /etc/sudoers.d
cat > /etc/sudoers.d/nyxpanel <<EOF
# nyxpanel may run the orchestrator and restart daemons. Nothing else.
Defaults!${INSTALL_DIR}/bin/proxy_manager.sh !requiretty
Cmnd_Alias NYX_MANAGER = ${INSTALL_DIR}/bin/proxy_manager.sh *
Cmnd_Alias NYX_DAEMONS = systemctl restart xray, \\
                        systemctl restart hysteria2, \\
                        systemctl restart sing-box-naive, \\
                        systemctl restart trojan-go, \\
                        systemctl restart tproxy-server, \\
                        systemctl reload caddy
$RUN_USER ALL=(root) NOPASSWD: NYX_MANAGER, NYX_DAEMONS
EOF
chmod 440 /etc/sudoers.d/nyxpanel
visudo -c -f /etc/sudoers.d/nyxpanel >/dev/null \
    || die "generated sudoers file is invalid"

# ------------------------------------------------------------------ units --
say "systemd units"
install -m 644 "$SOURCE_DIR/ops/panel.service" /etc/systemd/system/panel.service
install -m 644 "$SOURCE_DIR/ops/nyxpanel-collector.service" \
              /etc/systemd/system/nyxpanel-collector.service
install -m 644 "$SOURCE_DIR/ops/nyxpanel-collector.timer" \
              /etc/systemd/system/nyxpanel-collector.timer

systemctl daemon-reload
systemctl enable --now nyxpanel-collector.timer >/dev/null 2>&1 || \
    warn "could not enable the collector timer"
systemctl restart panel.service
sleep 2
systemctl is-active --quiet panel.service \
    || die "panel.service did not start — check: journalctl -u panel -n 40"
say "panel.service active"

# D5: the collector must actually run and produce rows.
if [ "$ROLE" != "node" ]; then
    say "verifying the traffic collector"
    if /usr/bin/python3 "$INSTALL_DIR/panel/collector.py" 2>&1 | tail -5; then
        warn "collector ran; it reports 0 bytes until traffic flows"
    else
        warn "collector exited non-zero — check its output above"
    fi
fi

# ------------------------------------------------------------------ caddy --
if [ "$SKIP_CADDY" -eq 1 ]; then
    warn "skipping Caddy (--no-caddy)"
elif [ -z "$DOMAIN" ]; then
    warn "no --domain given, skipping Caddy"
else
    say "configuring Caddy for $DOMAIN"
    CADDYFILE=/etc/caddy/Caddyfile
    touch "$CADDYFILE"
    if grep -q "$DOMAIN" "$CADDYFILE"; then
        warn "Caddyfile already mentions $DOMAIN, leaving it alone"
    else
        HASH=$(caddy hash-password --plaintext "$PANEL_PASSWORD")
        # H9: the password is known before Caddy is reloaded, never CHANGEME.
        cat >> "$CADDYFILE" <<EOF

# nyxpanel — added $(date -Is)
$DOMAIN:443 {
    handle /static/* {
        root * $INSTALL_DIR/panel
        file_server
    }
    handle {
        reverse_proxy 127.0.0.1:5000
    }
}
EOF
        # Basic auth goes in front of the panel, because /self/* is proxied and
        # the panel's own session check is not a substitute for edge auth.
        sed -i "/^$DOMAIN:443 {/a\\    basicauth {\\n        admin $HASH\\n    }" "$CADDYFILE"
        caddy validate --config "$CADDYFILE" \
            || die "generated Caddyfile is invalid — not reloading"
        systemctl reload caddy
        say "Caddy reloaded"
    fi
fi

# ------------------------------------------------------------------ admin --
# The panel's own admin account must exist with a real password.
if [ "$ROLE" != "node" ]; then
    say "seeding the admin account"
    PANEL_PASSWORD="$PANEL_PASSWORD" \
    STATE_DIR="$STATE_DIR" \
    python3 - <<'PY' || warn "could not seed the admin account"
import os, sqlite3
from werkzeug.security import generate_password_hash
db = sqlite3.connect(os.path.join(os.environ["STATE_DIR"], "panel.db"))
db.execute("""CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL,
    password_hash TEXT DEFAULT '', created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP, traffic_limit_bytes INTEGER DEFAULT 0,
    active INTEGER DEFAULT 1, note TEXT DEFAULT '', role TEXT DEFAULT 'user')""")
db.execute("INSERT INTO users (username, password_hash, role, active) "
           "VALUES ('admin', ?, 'admin', 1) "
           "ON CONFLICT(username) DO UPDATE SET password_hash=excluded.password_hash",
           (generate_password_hash(os.environ["PANEL_PASSWORD"]),))
db.commit(); db.close()
PY
fi

echo
echo "============================================"
echo "  nyxpanel installed ($MODE / $ROLE)"
echo "  panel dir : $INSTALL_DIR"
echo "  state dir : $STATE_DIR"
echo "  config    : $CONF_DIR/panel.env  (PANEL_SECRET, CRON_SECRET)"
echo "  logs      : $LOG_DIR, journalctl -u panel"
if [ -n "$DOMAIN" ] && [ "$SKIP_CADDY" -eq 0 ]; then
    echo "  url       : https://$DOMAIN/self/login"
fi
if [ "${GENERATED_PASSWORD:-0}" = "1" ]; then
    echo "  login     : admin"
    echo "  password  : $PANEL_PASSWORD"
    echo "  ^ shown once and not stored in plaintext — save it now"
fi
echo "============================================"

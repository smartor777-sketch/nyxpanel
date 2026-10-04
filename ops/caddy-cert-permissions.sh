#!/bin/bash
# Keep Caddy's certificates readable by the services that terminate TLS with
# them.
#
# Why this exists. Caddy writes certificate and key files as mode 0600 owned by
# caddy:nyxcerts. Group ownership is therefore decorative — nothing can read them
# through the group. hysteria2, sing-box (naive) and trojan-go run as their own
# unprivileged users and point their TLS config straight at those files.
#
# The only reason this went unnoticed for weeks: Caddy renewed the certificate on
# 2026-09-28, and the already-running processes kept the file descriptor they had
# opened before that. Every service kept working while unable to open the file
# again. The moment anything restarted one of them — adding a Hysteria user does
# exactly that — it failed with
#
#   tls.cert: open /var/lib/caddy/.../vpn.example.com.crt: permission denied
#
# and, with Restart=always, crash-looped every three seconds.
#
# So the mode is corrected here, and a timer re-applies it after every renewal.
set -euo pipefail

CADDY_DIR=${CADDY_DIR:-/var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory}
CERT_GROUP=${CERT_GROUP:-nyxcerts}

if ! getent group "$CERT_GROUP" >/dev/null; then
    echo "group $CERT_GROUP does not exist, nothing to do" >&2
    exit 0
fi

if [ ! -d "$CADDY_DIR" ]; then
    echo "$CADDY_DIR does not exist yet, nothing to do" >&2
    exit 0
fi

changed=0
while IFS= read -r -d '' f; do
    case "$f" in
        *.crt|*.key|*.pem) ;;
        *) continue ;;
    esac
    mode=$(stat -c '%a' "$f")
    # 640 or already looser: leave it alone.
    if [ "$mode" = "600" ] || [ "$mode" = "400" ]; then
        chgrp "$CERT_GROUP" "$f"
        chmod g+r "$f"
        echo "  fixed $f ($mode -> $(stat -c '%a' "$f"))"
        changed=$((changed + 1))
    fi
done < <(find "$CADDY_DIR" -type f -print0 2>/dev/null)

echo "certificate permissions checked, $changed file(s) adjusted"
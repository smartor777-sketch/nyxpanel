#!/bin/bash
# nyx-revoke.sh — real revocation and restore for nyxpanel (D1 / C3).
#
# Sourced by proxy_manager.sh. Depends on variables and helpers the caller has
# already defined: BASE_DIR, AWG_CONFIG, AWG_INTERFACE, XRAY_CONFIG, XRAY_SERVICE,
# HY2_CONFIG, NAIVE_CONFIG, TROJAN_SERVICE, GREEN, YELLOW, RED, NC, _sync_log,
# check_user_exists.
#
# Why this exists: the panel's "disable user" only wrote active=0 in SQLite. The
# peer stayed live in awg0.conf, in xray, in every other daemon, and in the
# subscription files, so the UI showed a disabled user whose VPN still worked.
#
# Revoke does NOT delete anything and does NOT reissue keys. Restore puts the same
# public key, same tunnel IP and same preshared key back, so a user blocked for a
# week resumes with nothing to re-scan.

NYX_SUSPEND_DIR="${NYX_SUSPEND_DIR:-$BASE_DIR/.suspended}"

# --- Xray runtime API (gRPC HandlerService) ---------------------------------
# Using it avoids `systemctl restart xray`, which drops every connected client.
# Returns 0 if the client was added/removed live, 1 if the caller must fall back
# to a config rewrite + restart.

# xray_remove_client / xray_add_client live in xray-reconcile.sh, which knows
# the two shapes the CLI wants: adu reads a config-shaped JSON file, rmu takes
# -tag plus plain emails.

# --- helpers ---------------------------------------------------------------

nyx_user_pubkey() {
    cat "$BASE_DIR/$1/.awg_pubkey" 2>/dev/null
}

nyx_user_ip() {
    grep -m1 '^Address = ' "$BASE_DIR/$1/${1}_awg.conf" 2>/dev/null \
        | awk '{print $3}' | cut -d/ -f1
}

nyx_user_psk() {
    grep -m1 '^PresharedKey = ' "$BASE_DIR/$1/${1}_awg.conf" 2>/dev/null \
        | awk '{print $3}'
}

# Remove a peer block from awg0.conf by its PublicKey, leaving everything else
# byte-identical. Inlined awk rather than a helper so the config rewrite stays
# one atomic step.
_nyx_strip_awg_peer() {
    local pub=$1 cfg=$2 tmp
    tmp=$(mktemp)
    awk -v pub="$pub" '
        /^PublicKey = / { inpeer = ($0 == "PublicKey = " pub) }
        /^\[Peer\]/ { inpeer = 0 }
        !inpeer { print }
    ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    # Drop the now-orphaned "# Peer: <name>" comment lines and collapse blanks.
    tmp=$(mktemp)
    awk '
        /^# Peer: / { pend = 1; next }
        /^$/ { if (pend) { pend = 0; next } }
        pend && /^\[/ { print; pend = 0; next }
        { print }
    ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    return 0
}

_nyx_restore_awg_peer() {
    local name=$1 pub=$2 ip=$3 psk=$4
    grep -qF "PublicKey = $pub" "$AWG_CONFIG" && return 0
    {
        printf '\n# Peer: %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
            "$name" "$pub" "$psk" "$ip"
    } >> "$AWG_CONFIG"
}

# --- revoke ---------------------------------------------------------------

nyx_revoke_user() {
    local username=$1
    [ -z "$username" ] && { echo "revoke_user: username required" >&2; return 1; }
    [ -d "$BASE_DIR/$username" ] || { echo "No such user: $username" >&2; return 1; }

    mkdir -p "$NYX_SUSPEND_DIR/$username"

    # Preserve exactly what restore needs.
    if [ -f "$BASE_DIR/$username/${username}_awg.conf" ]; then
        cp -a "$BASE_DIR/$username/${username}_awg.conf" "$NYX_SUSPEND_DIR/$username/awg.conf"
    fi
    if [ -f "$BASE_DIR/$username/.awg_pubkey" ]; then
        cp -a "$BASE_DIR/$username/.awg_pubkey" "$NYX_SUSPEND_DIR/$username/awg_pubkey"
    fi

    local touched="" failed=""

    # --- AmneziaWG: detach via syncconf, no interface bounce ---
    local pub; pub=$(nyx_user_pubkey "$username")
    if [ -n "$pub" ] && [ -f "$AWG_CONFIG" ] && grep -qF "$pub" "$AWG_CONFIG"; then
        _nyx_strip_awg_peer "$pub" "$AWG_CONFIG"
        # The peer block was just deleted from awg0.conf, so the drift guard
        # must not treat that as something to refuse.
        if awg_apply_config "revoke:$username" 1; then touched="$touched awg"
        else failed="$failed awg"; fi
    fi

    # --- Xray: runtime API, fall back to rewrite+restart ---
    local uuid email
    uuid=$(jq -r --arg u "$username" '.[$u] // empty' /etc/xray/users.json 2>/dev/null)
    if [ -n "$uuid" ] && [ -f "$XRAY_CONFIG" ]; then
        email=$(jq -r --arg id "$uuid" \
                '[.inbounds[0].settings.clients[] | select(.id==$id) | .email // empty][0] // empty' \
                "$XRAY_CONFIG" 2>/dev/null)
        if [ -z "$email" ] || [ "$email" = "null" ]; then email="$username"; fi
        if xray_remove_client "$email"; then
            touched="$touched vless:api"
        else
            jq --arg id "$uuid" \
               '.inbounds[0].settings.clients = [.inbounds[0].settings.clients[] | select(.id != $id)]' \
               "$XRAY_CONFIG" > /tmp/nyx_xray_rev.json \
                && mv /tmp/nyx_xray_rev.json "$XRAY_CONFIG" \
                && { systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 && touched="$touched vless:restart" \
                     || failed="$failed vless"; }
        fi
    fi

    # --- Protocols with no runtime API: the credential keeps existing in the
    #     config, so we must bounce the daemon to stop honouring it. Batched by
    #     the caller when possible; here it is at most one restart each.
    if [ -f "$HY2_CONFIG" ] && grep -qF "$username" "$HY2_CONFIG" 2>/dev/null; then
        systemctl restart hysteria2 >/dev/null 2>&1 && touched="$touched hy2:restart" \
            || failed="$failed hy2"
    fi
    if [ -f "$NAIVE_CONFIG" ] && grep -qF "$username" "$NAIVE_CONFIG" 2>/dev/null; then
        systemctl restart sing-box-naive >/dev/null 2>&1 && touched="$touched naive:restart" \
            || failed="$failed naive"
    fi
    if [ -f "$TROJAN_USERS_FILE" ] && jq -e --arg u "$username" 'has($u)' "$TROJAN_USERS_FILE" >/dev/null 2>&1; then
        systemctl restart "$TROJAN_SERVICE" >/dev/null 2>&1 && touched="$touched troy:restart" \
            || failed="$failed troy"
    fi

    date -Is > "$BASE_DIR/$username/.revoked"
    audit_line="revoke user=$username ok=[${touched# }] failed=[${failed# }]"
    echo "$audit_line"
    _sync_log "$audit_line"

    if [ -n "$failed" ]; then
        echo "REVOCATION INCOMPLETE — panel will show this as unconfirmed: $failed" >&2
        return 1
    fi
    return 0
}

# --- restore --------------------------------------------------------------
# Same keys, same IP, same PSK. Nothing for the user to re-import.

nyx_restore_user() {
    local username=$1
    [ -z "$username" ] && { echo "restore_user: username required" >&2; return 1; }
    [ -d "$BASE_DIR/$username" ] || { echo "No such user: $username" >&2; return 1; }

    local touched="" failed=""
    local susp="$NYX_SUSPEND_DIR/$username"

    # --- AmneziaWG ---
    if [ -f "$susp/awg_pubkey" ] && [ -f "$susp/awg.conf" ]; then
        local pub ip psk
        pub=$(cat "$susp/awg_pubkey")
        ip=$(nyx_user_ip "$username")
        psk=$(nyx_user_psk "$username")
        if [ -n "$pub" ] && [ -n "$ip" ]; then
            _nyx_restore_awg_peer "$username" "$pub" "$ip" "$psk"
            if awg_apply_config "restore:$username"; then touched="$touched awg"
            else failed="$failed awg"; fi
        else
            failed="$failed awg:no-suspended-state"
        fi
    fi

    # --- Xray ---
    local uuid
    uuid=$(jq -r --arg u "$username" '.[$u] // empty' /etc/xray/users.json 2>/dev/null)
    if [ -n "$uuid" ] && [ -f "$XRAY_CONFIG" ]; then
        if jq -e --arg id "$uuid" \
             '[.inbounds[0].settings.clients[] | select(.id==$id)] | length > 0' \
             "$XRAY_CONFIG" >/dev/null 2>&1; then
            touched="$touched vless:already-present"
        elif xray_add_client "$uuid" "$username" "$XRAY_CONFIG"; then
            touched="$touched vless:api"
        else
            jq --arg id "$uuid" --arg email "$username" \
               '.inbounds[0].settings.clients += [{"id":$id,"flow":"","email":$email}]' \
               "$XRAY_CONFIG" > /tmp/nyx_xray_add.json \
                && mv /tmp/nyx_xray_add.json "$XRAY_CONFIG" \
                && { systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 && touched="$touched vless:restart" \
                     || failed="$failed vless"; }
        fi
    fi

    # --- daemons without a runtime API ---
    systemctl restart hysteria2 >/dev/null 2>&1 && touched="$touched hy2:restart"
    systemctl restart sing-box-naive >/dev/null 2>&1 && touched="$touched naive:restart"
    systemctl restart "$TROJAN_SERVICE" >/dev/null 2>&1 && touched="$touched troy:restart"

    rm -f "$BASE_DIR/$username/.revoked"
    local line="restore user=$username ok=[${touched# }] failed=[${failed# }]"
    echo "$line"
    _sync_log "$line"
    [ -z "$failed" ] || return 1
    return 0
}

# --- expiry ---------------------------------------------------------------
# Expiry now performs a real revocation. Before this it only wrote active=0 in
# SQLite, which changed nothing on any daemon.

nyx_expire_check() {
    local revoked=0 user
    [ -f "$BASE_DIR/.registry" ] || return 0
    while IFS= read -r user || [ -n "$user" ]; do
        [ -z "$user" ] && continue
        [ "$user" = "admin" ] && continue
        [ -f "$BASE_DIR/$user/.revoked" ] && continue
        if nyx_revoke_user "$user" >/dev/null 2>&1; then
            echo "expired: $user"
            revoked=$((revoked+1))
        else
            echo "expired but revoke incomplete: $user" >&2
        fi
    done < "$BASE_DIR/.registry"
    echo "expire_check: revoked=$revoked"
    return 0
}

#!/bin/bash
# Thin command surface the panel calls. The implementation lives in
# lib/nyx-revoke.sh, which proxy_manager.sh sources, so both the CLI and the
# panel go through exactly one code path.

nyx_revoke_dispatch() {
    case "$1" in
        revoke_user)  shift; nyx_revoke_user  "$@" ;;
        restore_user) shift; nyx_restore_user "$@" ;;
        expire_check) shift; nyx_expire_check "$@" ;;
        *) echo "usage: nyx-revoke.sh {revoke_user|restore_user|expire_check} [username]" >&2
           return 2 ;;
    esac
}

# Allow both `source`-ing and direct execution.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    : "${BASE_DIR:=/root/proxy_users}"
    : "${AWG_CONFIG:=/etc/amnezia/amneziawg/awg0.conf}"
    : "${AWG_INTERFACE:=awg0}"
    : "${XRAY_CONFIG:=/usr/local/etc/xray/config.json}"
    : "${XRAY_SERVICE:=xray}"
    : "${HY2_CONFIG:=/etc/hysteria/config.json}"
    : "${NAIVE_CONFIG:=/etc/sing-box/config.json}"
    : "${TROJAN_SERVICE:=trojan-go}"
    : "${TROJAN_USERS_FILE:=/etc/sing-box/trojan_users.json}"
    : "${XRAY_API:=127.0.0.1:10085}"
    GREEN=''; YELLOW=''; RED=''; NC=''
    check_user_exists() { [ -d "$BASE_DIR/$1" ]; }
    _sync_log() { echo "$(date -Is) $*" >> /var/log/nyxproxy/revoke.log 2>/dev/null || true; }
    # Reuse the interface apply helper when it is available, otherwise fall back
    # to a bounce and say so.
    if ! declare -F awg_apply_config >/dev/null 2>&1; then
        awg_apply_config() {
            mkdir -p /var/log/nyxproxy
            if ip link show "$AWG_INTERFACE" >/dev/null 2>&1; then
                local tool="awg"; command -v awg >/dev/null 2>&1 || tool="wg"
                local s; s=$(wg-quick strip "$AWG_INTERFACE" 2>/dev/null)
                if [ -n "$s" ] && "$tool" syncconf "$AWG_INTERFACE" <(echo "$s") 2>/dev/null; then
                    echo "$(date -Is) syncconf OK ($1)" >> /var/log/nyxproxy/sync.log
                    return 0
                fi
            fi
            awg-quick down "$AWG_INTERFACE" 2>/dev/null || true
            awg-quick up "$AWG_INTERFACE" 2>/dev/null || true
            echo "$(date -Is) FALLBACK bounce ($1)" >> /var/log/nyxproxy/sync.log
            return 0
        }
    fi
    # shellcheck source=lib/nyx-revoke.sh
    . "$HERE/nyx-revoke.sh"
    nyx_revoke_dispatch "$@"
fi

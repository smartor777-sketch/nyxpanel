#!/bin/bash

# ==============================================================================
# ПРОКСИ-МЕНЕДЖЕР (Версия 0.9 - Hysteria 2 + AmneziaWG + NaiveProxy(sing-box) + Mieru + olcRTC + VLESS+XHTTP+REALITY) 
# ==============================================================================

# Per-host settings must be read BEFORE the defaults below.
#
# The settings block uses VAR="${VAR:-default}", so every variable already holds
# a non-empty value by the time anything else runs. load_env_overrides() skips
# variables that already hold one — correct for an explicit caller override, but
# it means a file-provided BASE_DIR can never beat the built-in default. The
# result was that the panel and the orchestrator used different directories: the
# panel /var/lib/nyxpanel/users, the orchestrator /root/proxy_users.
#
# So the file is read here, and the defaults below fill in only what is still
# unset. Reading it later cannot work.
nyx_env_file="${NYX_ENV:-/etc/nyxpanel/proxy.env}"
if [ -f "$nyx_env_file" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line%%#*}"
        _line="${_line#"${_line%%[![:space:]]*}"}"
        [ -z "$_line" ] && continue
        case "$_line" in *=*) ;; *) continue ;; esac
        _key="${_line%%=*}"
        _val="${_line#*=}"
        _key="${_key%"${_key##*[![:space:]]}"}"
        _val="${_val#"${_val%%[![:space:]]*}"}"
        _val="${_val%"${_val##*[![:space:]]}"}"
        case "$_val" in
            \"*\") _val="${_val:1:${#_val}-2}" ;;
            \'*\') _val="${_val:1:${#_val}-2}" ;;
        esac
        # Only when genuinely unset, so an exported override still wins.
        if [ -z "${!_key:-}" ]; then
            printf -v "$_key" '%s' "$_val"
            export "$_key"
        fi
    done < "$nyx_env_file"
fi

# --- НАСТРОЙКИ ---
BASE_DIR="${BASE_DIR:-/root/proxy_users}"
REGISTRY_FILE="${REGISTRY_FILE:-$BASE_DIR/.registry}"

# Пути к конфигам серверов
HY2_CONFIG="${HY2_CONFIG:-/etc/hysteria/config.yaml}"
AWG_CONFIG="${AWG_CONFIG:-/etc/amnezia/amneziawg/awg0.conf}" 
NAIVE_CONFIG="${NAIVE_CONFIG:-/etc/sing-box/config.json}"
AWG_INTERFACE="${AWG_INTERFACE:-awg0}"

# Параметры сервера
SERVER_DOMAIN="${SERVER_DOMAIN:-vpn.example.com}"
AWG_SUBNET="${AWG_SUBNET:-10.9.9}"
NAIVE_PORT="${NAIVE_PORT:-8443}" 
# H4: infrastructure addresses and secrets come from /etc/nyxpanel/proxy.env,
# never from the body of this file. See ops/nyxpanel.env.example.
MIERU_IP="${MIERU_IP:-}"
MIERU_PORTS="${MIERU_PORTS:-444-448}"
MIERU_CONFIG="${MIERU_CONFIG:-/etc/mita/server.json}"

# olcRTC
OLRTC_USERS_FILE="${OLRTC_USERS_FILE:-/etc/olcrtc/users.json}"
OLRTC_CONFIG="${OLRTC_CONFIG:-/root/.config/olcrtc/server.yaml}"
OLRTC_SERVICE="${OLRTC_SERVICE:-olcrtc}"
OLRTC_ICE="${OLRTC_ICE:-ws://${SERVER_DOMAIN}:30001/ice}"
OLRTC_ROOM_URL="${OLRTC_ROOM_URL:-}"
OLRTC_CRYPTO_KEY="${OLRTC_CRYPTO_KEY:-}"

# Trojan
TROJAN_USERS_FILE="${TROJAN_USERS_FILE:-/etc/sing-box/trojan_users.json}"
TROJAN_PORT=9443
TROJAN_CERT="${TROJAN_CERT:-/var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${SERVER_DOMAIN}/${SERVER_DOMAIN}.crt}"
TROJAN_KEY="${TROJAN_KEY:-/var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${SERVER_DOMAIN}/${SERVER_DOMAIN}.key}"
TROJAN_SERVICE="${TROJAN_SERVICE:-trojan-go}"

# VLESS+XHTTP+REALITY
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
VLESS_USERS_FILE="${VLESS_USERS_FILE:-/etc/xray/users.json}"
XRAY_SERVICE="${XRAY_SERVICE:-xray}"
VLESS_HOST="${VLESS_HOST:-${SERVER_DOMAIN}}"
VLESS_PORT="${VLESS_PORT:-4433}"
VLESS_SNI="${VLESS_SNI:-}"
VLESS_PUBLIC_KEY="${VLESS_PUBLIC_KEY:-}"
VLESS_SHORT_ID="${VLESS_SHORT_ID:-}"
VLESS_PATH="${VLESS_PATH:-%2Fvless}"

# Цвета
GREEN='\033[1;92m'
RED='\033[1;91m'
YELLOW='\033[1;93m'
WHITE='\033[1;97m'
CYAN='\033[1;96m'
NC='\033[0m'

# --- ИНИЦИАЛИЗАЦИЯ ---
# Переопределяет константы выше актуальными значениями из серверных конфигов
load_server_settings() {
    local _d _cfg _p _port _shortid _priv _pub _path _room _key _tc _tk _ports

    _d=$(grep -ohE '[A-Za-z0-9*.-]+\.example\.com' /etc/caddy/Caddyfile 2>/dev/null | head -1)
    [ -z "$_d" ] && _d=$(grep -ohE '^[A-Za-z0-9*.-]+\.[A-Za-z]{2,}' /etc/caddy/Caddyfile 2>/dev/null | head -1)
    [ -n "$_d" ] && SERVER_DOMAIN="$_d"
    VLESS_HOST="$SERVER_DOMAIN"

    if [ -f "$XRAY_CONFIG" ]; then
        _port=$(jq -r '.inbounds[] | select(.protocol=="vless") | .port // empty' "$XRAY_CONFIG" 2>/dev/null | head -1)
        _shortid=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.shortIds[0] // empty' "$XRAY_CONFIG" 2>/dev/null | head -1)
        _priv=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.privateKey // empty' "$XRAY_CONFIG" 2>/dev/null | head -1)
        _path=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.xhttpSettings.path // empty' "$XRAY_CONFIG" 2>/dev/null | head -1)
        [ -n "$_port" ] && VLESS_PORT="$_port"
        [ -n "$_shortid" ] && VLESS_SHORT_ID="$_shortid"
        [ -n "$_path" ] && VLESS_PATH="${_path//\//%2F}"
        if [ -n "$_priv" ] && command -v xray &>/dev/null; then
            _pub=$(xray x25519 -i "$_priv" 2>/dev/null | sed -nE 's/.*\(PublicKey\): *([^ ]+).*/\1/p')
            _pub="${_pub%=}"
            [ -n "$_pub" ] && VLESS_PUBLIC_KEY="$_pub"
        fi
    fi

    _cfg=""
    for _p in /etc/olcrtc/server.yaml /root/.config/olcrtc/server.yaml; do
        [ -f "$_p" ] && _cfg="$_p" && break
    done
    if [ -n "$_cfg" ]; then
        _room=$(sed -nE 's/^[[:space:]]+id:[[:space:]]*"?([^"]*)"?.*/\1/p' "$_cfg" | head -1)
        _key=$(sed -nE 's/^[[:space:]]+key:[[:space:]]*"?([^"]*)"?.*/\1/p' "$_cfg" | head -1)
        [ -n "$_room" ] && OLRTC_ROOM_URL="$_room"
        [ -n "$_key" ] && OLRTC_CRYPTO_KEY="$_key"
        OLRTC_ICE="ws://${SERVER_DOMAIN}:30001/ice"
    fi

    if [ -f /etc/trojan-go/config.json ]; then
        _tc=$(jq -r '.ssl.cert // empty' /etc/trojan-go/config.json 2>/dev/null)
        _tk=$(jq -r '.ssl.key // empty' /etc/trojan-go/config.json 2>/dev/null)
        [ -n "$_tc" ] && TROJAN_CERT="$_tc"
        [ -n "$_tk" ] && TROJAN_KEY="$_tk"
    fi

    if [ -f "$MIERU_CONFIG" ]; then
        _ports=$(jq -r '[.portBindings[]? | .portRange] | join(",")' "$MIERU_CONFIG" 2>/dev/null)
        [ -n "$_ports" ] && MIERU_PORTS="$_ports"
    fi
}

# Hand newly created files to the state directory's owner.
#
# The orchestrator runs as root through sudo, so without this every config it
# writes lands root:root 644 — readable by the panel but not deletable or
# rewritable by it, which breaks removing a protocol and revoking access.
_fix_state_owner() {
    local dir=${1:-$BASE_DIR}
    local owner
    owner=$(stat -c '%U:%G' "$dir" 2>/dev/null) || return 0
    [ "$owner" = "root:root" ] && return 0
    chown -R "$owner" "$dir" 2>/dev/null || true
    # Configs hold private keys: keep them group-only.
    find "$dir" -type f \
        \( -name '*.conf' -o -name '*.json' -o -name '*.uri' -o -name '.awg_pubkey' \) \
        -exec chmod 640 {} + 2>/dev/null || true
}

init() {
    mkdir -p "$BASE_DIR"
    touch "$REGISTRY_FILE"
    
    if ! command -v jq &> /dev/null; then echo -e "${RED}Ошибка: установите jq (apt install jq -y)${NC}"; exit 1; fi
    if ! command -v yq &> /dev/null; then echo -e "${RED}Ошибка: установите yq (apt install yq -y)${NC}"; exit 1; fi
    if ! command -v qrencode &> /dev/null; then echo -e "${RED}Ошибка: установите qrencode (apt install qrencode -y)${NC}"; exit 1; fi
    if ! command -v awg &> /dev/null; then echo -e "${RED}Ошибка: утилита awg не найдена. Установлен ли AmneziaWG?${NC}"; exit 1; fi
    # The env file was already read above, before the defaults; only the log
    # directory is left to set up.
    SYNC_LOG="${SYNC_LOG:-/var/log/nyxpanel/sync.log}"
    mkdir -p "$(dirname "$SYNC_LOG")" 2>/dev/null || true
    load_server_settings
    require_config
    load_revoke_lib
}

# H4/D3: a missing value must be a loud error, not an empty string that later
# produces a malformed link — which is exactly how a VLESS URI came out blank.
require_config() {
    local missing=()
    [ -z "$SERVER_DOMAIN" ] && missing+=("SERVER_DOMAIN")
    [ -z "$VLESS_SNI" ] && missing+=("VLESS_SNI")
    [ -z "$VLESS_PUBLIC_KEY" ] && missing+=("VLESS_PUBLIC_KEY")
    [ -z "$VLESS_SHORT_ID" ] && missing+=("VLESS_SHORT_ID")
    [ -z "$AWG_CONFIG" ] && missing+=("AWG_CONFIG")
    [ -z "$AWG_INTERFACE" ] && missing+=("AWG_INTERFACE")
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Ошибка: не заданы переменные: ${missing[*]}${NC}" >&2
        echo -e "${RED}Задайте их в ${NYX_ENV:-/etc/nyxpanel/proxy.env}${NC}" >&2
        echo -e "${RED}Проверка настроек не пройдена, работа остановлена.${NC}" >&2
        exit 78   # EX_CONFIG
    fi
    return 0
}

# Revoke/restore live in their own file so the CLI, the panel and any future
# agent share one implementation instead of three drifting copies.
load_revoke_lib() {
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local lib
    for lib in nyx-revoke.sh xray-reconcile.sh; do
        local cand=""
        [ -f "$here/lib/$lib" ] && cand="$here/lib/$lib"
        [ -z "$cand" ] && [ -f "/opt/nyxpanel/bin/lib/$lib" ] && cand="/opt/nyxpanel/bin/lib/$lib"
        if [ -z "$cand" ]; then
            echo -e "${RED}Ошибка: не найден lib/$lib.${NC}" >&2
            return 1
        fi
        # shellcheck source=/dev/null
        . "$cand"
    done
    return 0
}

# Per-host values live in one place instead of being edited into this script's
# body on every machine, which is how the four copies of it drifted apart.
#
# The file is parsed, not sourced. Sourcing it broke on real values:
#   AWG_ALLOWED_IPS=0.0.0.0/0, ::/0
# has a space, so bash treated "::/0" as a command name and errored mid-load.
#
# Values already present in the environment win, so an explicit override such as
#   AWG_INTERFACE=awgtest0 bash proxy_manager.sh sync_awg
# is not silently replaced by the file.
load_env_overrides() {
    local env_file="${NYX_ENV:-/etc/nyxpanel/proxy.env}"
    [ -f "$env_file" ] || return 0

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        [ -z "$line" ] && continue
        case "$line" in *=*) ;; *) continue ;; esac

        key="${line%%=*}"
        value="${line#*=}"
        # trim surrounding whitespace
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        # strip one layer of matching quotes
        case "$value" in
            \"*\") value="${value:1:${#value}-2}" ;;
            \'*\') value="${value:1:${#value}-2}" ;;
        esac

        # Caller-supplied values take precedence over the file.
        #
        # Non-empty, not merely defined: the settings block declares things as
        # ${VAR:-}, so every one of them exists as an empty string before this
        # runs. Testing for existence made the file unreachable for every key.
        # ${!key:-} rather than ${!key}: the latter trips `set -u` when the key
        # is not set at all, which is the normal case for most entries.
        if [ -n "${!key:-}" ]; then
            continue
        fi
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$env_file"

    SYNC_LOG="${SYNC_LOG:-/var/log/nyxpanel/sync.log}"
    mkdir -p "$(dirname "$SYNC_LOG")" 2>/dev/null || true
}

_sync_log() {
    [ -n "${SYNC_LOG:-}" ] && echo "$(date -Is) $*" >> "$SYNC_LOG" 2>/dev/null || true
}

# D2: apply awg0.conf to the live interface WITHOUT bouncing it.
#
# The previous code did `awg-quick down` + `awg-quick up`, which tears the whole
# interface down, so adding one user dropped every connected user.
#
# Two things this must get right, and the naive version got both wrong:
#   1. `wg-quick strip <iface>` reads the LIVE kernel state, so feeding it back
#      to `syncconf` is a no-op that never applies a config-file change.
#      The payload has to be built from the config file.
#   2. `syncconf` reconciles peers, so a config file that is missing peers that
#      exist live will silently delete them. Guard against that, and against a
#      private key that does not match the running interface.

# Build a syncconf payload from the config file.
#
# Peers only. syncconf reconciles peers and refuses the interface's PrivateKey
# outright ("Line unrecognized: PrivateKey=..."), so the key must not be sent —
# it is verified separately by guard 1 below.
#
# AmneziaWG's Jc/Jmin/Jmax/S1..S4/H1..H4/I1/I5 parameters are interface-level
# tunables that only take effect on a fresh interface, not per-peer data, so they
# are excluded too. Changing them still requires a manual bounce, which the
# comment below says out loud rather than pretending otherwise.
_awg_syncconf_payload() {
    local conf=$1
    awk '
        /^\[Peer\]/ { inpeer = 1; print; next }
        /^\[/       { inpeer = 0; next }
        inpeer && /^[[:space:]]*(PublicKey|PresharedKey|AllowedIPs)[[:space:]]*=/ {
            sub(/^[[:space:]]+/, "")
            print
            next
        }
    ' "$conf"
}

# How to push a config change onto the live interface.
#
#   peer    (default) one `awg set <if> peer ...` per changed peer. Adds, updates
#           and removes peers in place; the interface is never torn down, so no
#           connected user is dropped. This is what makes adding a user safe.
#   bounce  awg-quick down + up. Drops every tunnel on the interface.
#
# Why per-peer and not `awg syncconf`: on amneziawg-tools 3.1 syncconf returns
# rc=0 and applies the peers, but `awg show <if> private-key` and `public-key`
# start returning empty afterwards, and whether traffic survives could not be
# established. Per-peer `awg set` was verified on the live interface: a peer was
# added with its preshared key, the PSK rotated in place, allowed-ips changed and
# the peer removed, with the interface private key readable throughout and the
# other peers untouched.
#
# Why this works at all — and why the previous code fell back to bouncing:
# in amneziawg-tools 3.1 `preshared-key` takes a FILE PATH, not the key value:
#
#     awg set awg0 peer <pub> preshared-key <value>    -> fopen: No such file or directory
#     awg set awg0 peer <pub> preshared-key /path/psk  -> works
#
# Keeping the key out of argv also means it does not show up in `ps`.
AWG_SYNC_MODE="${AWG_SYNC_MODE:-peer}"

# amneziawg-tools wants the preshared key in a file. 0600, removed immediately:
# a stray PSK file is readable by anyone with shell on the box.
_nyx_psk_file() {
    local psk=$1 dir f
    dir="${XDG_RUNTIME_DIR:-/run}"
    f=$(mktemp "$dir/nyx-psk.XXXXXX") || return 1
    chmod 600 "$f"
    printf '%s' "$psk" > "$f"
    printf '%s' "$f"
}

# Desired peers from the config file: "pubkey psk allowed-ips" per line.
_nyx_desired_peers() {
    awk '
        /^[[:space:]]*#/ { next }
        /^\[/ { next }
        /^[[:space:]]*PublicKey[[:space:]]*=/ {
            if (pk != "") print pk, psk, ips
            pk = $3; psk = ""; ips = ""; next
        }
        /^[[:space:]]*PresharedKey[[:space:]]*=/ { psk = $3; next }
        /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
            ips = (ips == "" ? $3 : ips "," $3); next
        }
        END { if (pk != "") print pk, psk, ips }
    ' "$AWG_CONFIG"
}

# Live peers, same shape: "pubkey psk allowed-ips".
_nyx_live_peers() {
    local tool=$1
    "$tool" show "$AWG_INTERFACE" dump 2>/dev/null | tail -n +2 | \
        awk 'NF >= 4 { print $1, ($2 == "(none)" ? "" : $2), $4 }'
}

awg_apply_config() {
    local reason="${1:-unknown}"

    if [ ! -f "$AWG_CONFIG" ]; then
        _sync_log "iface=$AWG_INTERFACE no config at $AWG_CONFIG, nothing applied"
        return 1
    fi

    local tool="awg"
    command -v awg >/dev/null 2>&1 || tool="wg"
    command -v "$tool" >/dev/null 2>&1 || {
        _sync_log "iface=$AWG_INTERFACE neither awg nor wg available"
        return 1
    }

    if ! ip link show "$AWG_INTERFACE" >/dev/null 2>&1; then
        _sync_log "iface=$AWG_INTERFACE absent, bringing it up (reason=$reason)"
        awg-quick up "$AWG_INTERFACE" 2>/dev/null || return 1
        return 0
    fi

    if [ "$AWG_SYNC_MODE" = "bounce" ]; then
        _sync_log "iface=$AWG_INTERFACE bounce (reason=$reason)"
        awg-quick down "$AWG_INTERFACE" 2>/dev/null || true
        awg-quick up "$AWG_INTERFACE" 2>/dev/null || {
            _sync_log "iface=$AWG_INTERFACE BOUNCEFAILED (reason=$reason)"
            return 1
        }
        return 0
    fi

    # Sanity check. Per-peer set never sends the interface key, so pointing at
    # the wrong config file would not fail loudly — it would quietly reconcile
    # the wrong peer set.
    local conf_pk live_pk
    conf_pk=$(awk '/^[[:space:]]*PrivateKey[[:space:]]*=/ {print $3; exit}' "$AWG_CONFIG")
    live_pk=$("$tool" show "$AWG_INTERFACE" private-key 2>/dev/null)
    if [ -z "$live_pk" ]; then
        _sync_log "iface=$AWG_INTERFACE private key unreadable, refusing (reason=$reason)"
        echo -e "${RED}Приватный ключ интерфейса $AWG_INTERFACE недоступен — изменений не вносилось.${NC}" >&2
        return 1
    fi
    if [ -z "$conf_pk" ] || [ "$conf_pk" != "$live_pk" ]; then
        _sync_log "iface=$AWG_INTERFACE KEY MISMATCH (reason=$reason) — refusing"
        echo -e "${RED}Приватный ключ в $AWG_CONFIG не совпадает с живым интерфейсом.${NC}" >&2
        return 1
    fi

    local desired live
    desired=$(_nyx_desired_peers)
    live=$(_nyx_live_peers "$tool")

    if [ -z "$desired" ]; then
        _sync_log "iface=$AWG_INTERFACE config lists no peers, refusing (reason=$reason)"
        echo -e "${RED}В $AWG_CONFIG нет ни одного пира — интерфейс НЕ изменён.${NC}" >&2
        return 1
    fi

    # Guard: peers live but absent from the file are drift, not intent. Removing
    # a connected peer here would look like a random disconnect.
    if [ "${AWG_ALLOW_PEER_REMOVAL:-0}" != "1" ]; then
        local orphans=""
        while read -r _pub _psk _ips; do
            [ -z "$_pub" ] && continue
            printf '%s\n' "$desired" | awk -v k="$_pub" '$1==k {found=1} END{exit !found}' \
                || orphans="$orphans $_pub"
        done <<< "$live"
        if [ -n "$orphans" ]; then
            local n
            n=$(printf '%s\n' $orphans | wc -l)
            _sync_log "iface=$AWG_INTERFACE $n live peers absent from config (reason=$reason) — refusing"
            echo -e "${RED}На интерфейсе есть $n пиров, которых нет в конфиге.${NC}" >&2
            echo -e "${RED}Интерфейс НЕ изменён. Разберитесь или задайте AWG_ALLOW_PEER_REMOVAL=1.${NC}" >&2
            return 1
        fi
    fi

    local added=0 updated=0 removed=0 failed=0
    local dpub dpsk dips lpub lpsk lips pf

    # --- add or update, one peer at a time ---
    while read -r dpub dpsk dips; do
        [ -z "$dpub" ] && continue
        lpub=$(printf '%s\n' "$live" | awk -v k="$dpub" '$1==k {print $1}')
        if [ -z "$lpub" ]; then
            pf=""
            [ -n "$dpsk" ] && pf=$(_nyx_psk_file "$dpsk")
            if [ -n "$pf" ]; then
                if "$tool" set "$AWG_INTERFACE" peer "$dpub" \
                        preshared-key "$pf" allowed-ips "$dips" 2>/dev/null; then
                    added=$((added+1))
                else
                    failed=$((failed+1))
                fi
                rm -f "$pf"
            elif "$tool" set "$AWG_INTERFACE" peer "$dpub" \
                        allowed-ips "$dips" 2>/dev/null; then
                added=$((added+1))
            else
                failed=$((failed+1))
            fi
            continue
        fi
        # Present: write only when something actually differs, so a reconcile is
        # a no-op rather than touching every peer.
        lpsk=$(printf '%s\n' "$live" | awk -v k="$dpub" '$1==k {print $2}')
        lips=$(printf '%s\n' "$live" | awk -v k="$dpub" '$1==k {print $3}')
        [ "$lpsk" = "$dpsk" ] && [ "$lips" = "$dips" ] && continue

        pf=""
        [ -n "$dpsk" ] && pf=$(_nyx_psk_file "$dpsk")
        if [ -n "$pf" ]; then
            if "$tool" set "$AWG_INTERFACE" peer "$dpub" preshared-key "$pf" \
                    allowed-ips "$dips" 2>/dev/null; then
                updated=$((updated+1))
            else
                failed=$((failed+1))
            fi
            rm -f "$pf"
        elif "$tool" set "$AWG_INTERFACE" peer "$dpub" \
                    allowed-ips "$dips" 2>/dev/null; then
            updated=$((updated+1))
        else
            failed=$((failed+1))
        fi
    done <<< "$desired"

    # --- remove ---
    while read -r lpub lpsk lips; do
        [ -z "$lpub" ] && continue
        dpub=$(printf '%s\n' "$desired" | awk -v k="$lpub" '$1==k {print $1}')
        [ -z "$dpub" ] || continue
        if "$tool" set "$AWG_INTERFACE" peer "$lpub" remove 2>/dev/null; then
            removed=$((removed+1))
        else
            failed=$((failed+1))
        fi
    done <<< "$live"

    _sync_log "iface=$AWG_INTERFACE peer-reconcile (reason=$reason) added=$added updated=$updated removed=$removed failed=$failed live_now=$("$tool" show "$AWG_INTERFACE" peers 2>/dev/null | wc -l)"

    if [ "$failed" -gt 0 ]; then
        echo -e "${RED}Часть изменений не применена (added=$added updated=$updated removed=$removed failed=$failed).${NC}" >&2
        echo -e "${RED}Подробности: ${SYNC_LOG:-журнал отсутствует}${NC}" >&2
        return 1
    fi
    return 0
}

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---
check_user_exists() {
    if [ ! -d "$BASE_DIR/$1" ]; then
        echo -e "${RED}Ошибка: Пользователь '$1' не найден.${NC}"
        return 1
    fi
    return 0
}

generate_qr() {
    local content=$1
    local output_path=$2
    echo "$content" | qrencode -t PNG -o "$output_path"
    echo -e "${GREEN}QR-код сохранен: $output_path${NC}"
}

init_mieru_config() {
    if [ ! -f "$MIERU_CONFIG" ]; then
        if [ -f "/tmp/mita.json" ]; then
            cp "/tmp/mita.json" "$MIERU_CONFIG"
            echo -e "${GREEN}Конфиг Mieru инициализирован из /tmp/mita.json${NC}"
        else
            jq -n \
              --arg ports "$MIERU_PORTS" \
              '{
                "portBindings": [{"portRange": $ports, "protocol": "TCP"}],
                "users": [],
                "loggingLevel": "INFO",
                "mtu": 1400
              }' > "$MIERU_CONFIG"
            echo -e "${GREEN}Конфиг Mieru создан заново${NC}"
        fi
    fi
}

apply_mieru_config() {
    if [ -f "$MIERU_CONFIG" ]; then
        if mita apply config "$MIERU_CONFIG"; then
            mita stop 2>/dev/null || true
            mita start
            echo -e "${GREEN}Конфиг Mieru применен, сервер перезапущен${NC}"
        else
            echo -e "${RED}Ошибка при применении конфига Mieru${NC}"
            return 1
        fi
    fi
}

# --- ФУНКЦИИ УПРАВЛЕНИЯ ПОЛЬЗОВАТЕЛЯМИ ---

add_user() {
    local username=$1
    if [ -z "$username" ]; then
        read -p "Введите имя нового пользователя (только латиница, цифры, _ и -): " username
    fi

    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Ошибка: Имя содержит недопустимые символы. Используйте только латиницу, цифры, _ и -${NC}"
        return 1
    fi

    if [ -d "$BASE_DIR/$username" ]; then
        echo -e "${YELLOW}Пользователь '$username' уже существует.${NC}"
        return 1
    fi

    mkdir -p "$BASE_DIR/$username"
    echo "$username" >> "$REGISTRY_FILE"
    echo -e "${GREEN}Пользователь '$username' создан. Папка: $BASE_DIR/$username${NC}"
}

del_user() {
    local username=$1
    
    if [ -z "$username" ]; then
        read -p "Введите имя пользователя для удаления: " username
    fi

    username=$(echo "$username" | xargs)
    if [ -z "$username" ]; then
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Имя не может быть пустым!${NC}"
        return 1
    fi

    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Недопустимые символы в имени.${NC}"
        return 1
    fi

    if ! check_user_exists "$username"; then 
        return 1
    fi

    if [ -t 0 ]; then
        read -p "Вы действительно хотите удалить пользователя '$username'? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${YELLOW}Удаление отменено.${NC}"
            return 1
        fi
    fi

    echo -e "${YELLOW}Удаляем пользователя '$username'...${NC}"
    
    local target_dir="$BASE_DIR/$username"
    if [[ "$target_dir" != "$BASE_DIR/"* ]]; then
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Попытка удаления за пределами директории!${NC}"
        return 1
    fi

    # 1. СНАЧАЛА удаляем из реестра
    if [ -f "$REGISTRY_FILE" ]; then
        grep -v -x -F "$username" "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp" && mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"
        echo -e "${GREEN}Удален из реестра.${NC}"
    fi

    # 2. Удаляем из AmneziaWG (если есть)
    if [ -f "$target_dir/.awg_pubkey" ] && [ -f "$AWG_CONFIG" ]; then
        awk -v user="$username" '
            $0 ~ "^# Peer: " user { skip=1; next }
            skip && /^\[Peer\]/ { skip=0 }
            !skip { print }
        ' "$AWG_CONFIG" > /tmp/awg_tmp.conf && mv /tmp/awg_tmp.conf "$AWG_CONFIG"

        awg_apply_config "del_user:$1"
        echo -e "${GREEN}Удален из AmneziaWG.${NC}"
    fi

    # 3. Удаляем из sing-box (NaiveProxy)
    if [ -f "$NAIVE_CONFIG" ]; then
        jq --arg user "$username" 'del(.inbounds[0].users[] | select(.username == $user))' \
          "$NAIVE_CONFIG" > /tmp/naive_config.tmp && mv /tmp/naive_config.tmp "$NAIVE_CONFIG"
        systemctl restart sing-box-naive
        echo -e "${GREEN}Удален из sing-box (NaiveProxy).${NC}"
    fi

    # 4. Удаляем из Mieru (если есть)
    if [ -f "$target_dir/${username}_mieru.json" ] && [ -f "$MIERU_CONFIG" ]; then
        init_mieru_config
        jq --arg name "$username" \
          'del(.users[] | select(.name == $name))' \
          "$MIERU_CONFIG" > "${MIERU_CONFIG}.tmp" && mv "${MIERU_CONFIG}.tmp" "$MIERU_CONFIG"
        apply_mieru_config
        echo -e "${GREEN}Удален из Mieru.${NC}"
    fi

    # 5. Удаляем из Hysteria 2 (если есть)
    if [ -f "$target_dir/${username}_hy2.json" ] && [ -f "$HY2_CONFIG" ]; then
        jq --arg user "$username" 'del(.auth.userpass[$user])' \
          "$HY2_CONFIG" > /tmp/hy2_config.tmp && mv /tmp/hy2_config.tmp "$HY2_CONFIG"
        systemctl restart hysteria2
        echo -e "${GREEN}Удален из Hysteria 2.${NC}"
    fi

    # 6. Удаляем из olcRTC (если есть)
    if { [ -f "$target_dir/${username}_olcrtc.json" ] || [ -f "$target_dir/${username}_olcrtc.yaml" ]; } && [ -f "$OLRTC_USERS_FILE" ]; then
        jq --arg user "$username" 'del(.[$user])' \
          "$OLRTC_USERS_FILE" > /tmp/olcrtc_users.tmp && mv /tmp/olcrtc_users.tmp "$OLRTC_USERS_FILE"
        echo -e "${GREEN}Удален из olcRTC.${NC}"
    fi

    # 7. Удаляем из VLESS (если есть)
    if [ -f "$target_dir/${username}_vless.uri" ] && [ -f "$VLESS_USERS_FILE" ]; then
        jq --arg user "$username" 'del(.[$user])' \
          "$VLESS_USERS_FILE" > /tmp/vless_users.tmp && mv /tmp/vless_users.tmp "$VLESS_USERS_FILE"
        update_xray_config
        echo -e "${GREEN}Удален из VLESS+XHTTP+REALITY.${NC}"
    fi

    # 7b. Удаляем из Trojan (если есть)
    if [ -f "$target_dir/${username}_troyan.json" ] && [ -f "$TROJAN_USERS_FILE" ]; then
        jq --arg user "$username" 'del(.[$user])' \
          "$TROJAN_USERS_FILE" > /tmp/trojan_users.tmp && mv /tmp/trojan_users.tmp "$TROJAN_USERS_FILE"
        update_trojango_config
        systemctl restart "$TROJAN_SERVICE"
        echo -e "${GREEN}Удален из Trojan.${NC}"
    fi

    # 8. Удаляем папку с ключами и файлами
    rm -rf "$target_dir"
    echo -e "${GREEN}Папка пользователя удалена.${NC}"
    
    echo -e "${GREEN}Пользователь '$username' полностью удален.${NC}"
}

list_users() {
    echo -e "${YELLOW}=== Список пользователей ===${NC}"
    if [ ! -f "$REGISTRY_FILE" ] || [ ! -s "$REGISTRY_FILE" ]; then
        echo "Список пуст."
        return
    fi

    while IFS= read -r user || [ -n "$user" ]; do
        [ -z "$user" ] && continue
        echo -e "${GREEN}👤 $user${NC}"
        [ -f "$BASE_DIR/$user/${user}_hy2.json" ] && echo "   - Hysteria 2 (✓)"
        [ -f "$BASE_DIR/$user/${user}_awg.conf" ] && echo "   - AmneziaWG (✓)"
        [ -f "$BASE_DIR/$user/${user}_naive.json" ] && echo "   - NaiveProxy (✓)" 
        [ -f "$BASE_DIR/$user/${user}_mieru.json" ] && echo "   - Mieru (✓)"
        [ -f "$BASE_DIR/$user/${user}_olcrtc.json" ] && echo "   - olcRTC (✓)"
        [ -f "$BASE_DIR/$user/${user}_vless.uri" ] && echo "   - VLESS+XHTTP+REALITY (✓)"
        [ -f "$BASE_DIR/$user/${user}_troyan.json" ] && echo "   - Trojan (✓)"
    done < "$REGISTRY_FILE"
}

remove_protocol() {
    local username=$1
    local proto=$2
    if [ -z "$username" ]; then
        read -p "Введите имя пользователя: " username
    fi
    if ! check_user_exists "$username"; then return 1; fi

    if [ -n "$proto" ]; then
        case "|hy2|awg|naive|mieru|olcrtc|vless|troy|" in
            *"|$proto|"*) selected_proto=$proto ;;
            *) echo "Unknown protocol: $proto" >&2; return 1 ;;
        esac
    fi

    if [ -z "$selected_proto" ]; then
        echo -e "${YELLOW}Доступные конфигурации для '$username':${NC}"
        local protocols=()
        local protocol_names=()
        
        if [ -f "$BASE_DIR/$username/${username}_hy2.json" ]; then
            protocols+=("hy2"); protocol_names+=("Hysteria 2")
        fi
        if [ -f "$BASE_DIR/$username/${username}_awg.conf" ]; then
            protocols+=("awg"); protocol_names+=("AmneziaWG")
        fi
        if [ -f "$BASE_DIR/$username/${username}_naive.json" ]; then
            protocols+=("naive"); protocol_names+=("NaiveProxy")
        fi
        if [ -f "$BASE_DIR/$username/${username}_mieru.json" ]; then
            protocols+=("mieru"); protocol_names+=("Mieru")
        fi
        if [ -f "$BASE_DIR/$username/${username}_olcrtc.json" ] || [ -f "$BASE_DIR/$username/${username}_olcrtc.yaml" ]; then
            protocols+=("olcrtc"); protocol_names+=("olcRTC")
        fi
        if [ -f "$BASE_DIR/$username/${username}_vless.uri" ]; then
            protocols+=("vless"); protocol_names+=("VLESS+XHTTP+REALITY")
        fi
        if [ -f "$BASE_DIR/$username/${username}_troyan.json" ]; then
            protocols+=("troy"); protocol_names+=("Trojan")
        fi

        for i in "${!protocols[@]}"; do
            echo -e "  ${GREEN}$((i+1)). ${protocol_names[$i]}${NC}"
        done
        if [ ${#protocols[@]} -eq 0 ]; then
            echo -e "${YELLOW}У пользователя '$username' нет активных конфигураций.${NC}"
            return 1
        fi

        echo -e "  ${RED}0. Отмена${NC}"
        read -p "Выберите протокол для удаления: " proto_choice
        if [ "$proto_choice" = "0" ] || [ -z "$proto_choice" ]; then
            echo -e "${YELLOW}Отменено.${NC}"; return 1
        fi
        if ! [[ "$proto_choice" =~ ^[0-9]+$ ]] || [ "$proto_choice" -lt 1 ] || [ "$proto_choice" -gt ${#protocols[@]} ]; then
            echo -e "${RED}Неверный выбор.${NC}"; return 1
        fi

        selected_proto=${protocols[$((proto_choice - 1))]}
        selected_name=${protocol_names[$((proto_choice - 1))]}

        read -p "Вы действительно хотите удалить конфигурацию '$selected_name' для пользователя '$username'? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${YELLOW}Удаление отменено.${NC}"; return 1
        fi
    fi

    [ -z "$selected_name" ] && case "$selected_proto" in
        hy2) selected_name="Hysteria 2" ;;
        awg) selected_name="AmneziaWG" ;;
        naive) selected_name="NaiveProxy" ;;
        mieru) selected_name="Mieru" ;;
        olcrtc) selected_name="olcRTC" ;;
        vless) selected_name="VLESS+XHTTP+REALITY" ;;
        troy) selected_name="Trojan" ;;
    esac

    echo -e "${YELLOW}Удаляем конфигурацию '$selected_name' для '$username'...${NC}"

    case $selected_proto in
        hy2)
            jq --arg user "$username" 'del(.auth.userpass[$user])' \
              "$HY2_CONFIG" > /tmp/hy2_config.tmp && mv /tmp/hy2_config.tmp "$HY2_CONFIG"
            systemctl restart hysteria2
            rm -f "$BASE_DIR/$username/${username}_hy2.json"
            rm -f "$BASE_DIR/$username/${username}_hy2.png"
            echo -e "${GREEN}Конфигурация Hysteria 2 удалена.${NC}"
            ;;
        awg)
            if [ -f "$BASE_DIR/$username/.awg_pubkey" ] && [ -f "$AWG_CONFIG" ]; then
                awk -v user="$username" '
                    $0 ~ "^# Peer: " user { skip=1; next }
                    skip && /^\[Peer\]/ { skip=0 }
                    !skip { print }
                ' "$AWG_CONFIG" > /tmp/awg_tmp.conf && mv /tmp/awg_tmp.conf "$AWG_CONFIG"

                awg_apply_config "remove_protocol:$username"
                rm -f "$BASE_DIR/$username/.awg_pubkey"
            fi
            rm -f "$BASE_DIR/$username/${username}_awg.conf"
            rm -f "$BASE_DIR/$username/${username}_awg.png"
            echo -e "${GREEN}Конфигурация AmneziaWG удалена.${NC}"
            ;;
        naive)
            if [ -f "$NAIVE_CONFIG" ]; then
                jq --arg user "$username" 'del(.inbounds[0].users[] | select(.username == $user))' \
                  "$NAIVE_CONFIG" > /tmp/naive_config.tmp && mv /tmp/naive_config.tmp "$NAIVE_CONFIG"
                systemctl restart sing-box-naive
            fi
            rm -f "$BASE_DIR/$username/${username}_naive.json"
            rm -f "$BASE_DIR/$username/${username}_naive.png"
            echo -e "${GREEN}Конфигурация NaiveProxy удалена.${NC}"
            ;;
        mieru)
            if [ -f "$BASE_DIR/$username/${username}_mieru.json" ] && [ -f "$MIERU_CONFIG" ]; then
                init_mieru_config
                jq --arg name "$username" \
                  'del(.users[] | select(.name == $name))' \
                  "$MIERU_CONFIG" > "${MIERU_CONFIG}.tmp" && mv "${MIERU_CONFIG}.tmp" "$MIERU_CONFIG"
                apply_mieru_config
            fi
            rm -f "$BASE_DIR/$username/${username}_mieru.json"
            rm -f "$BASE_DIR/$username/${username}_mieru.png"
            echo -e "${GREEN}Конфигурация Mieru удалена.${NC}"
            ;;
        olcrtc)
            if [ -f "$OLRTC_USERS_FILE" ]; then
                jq --arg user "$username" 'del(.[$user])' \
                  "$OLRTC_USERS_FILE" > /tmp/olcrtc_users.tmp && mv /tmp/olcrtc_users.tmp "$OLRTC_USERS_FILE"
            fi
            rm -f "$BASE_DIR/$username/${username}_olcrtc.json" "$BASE_DIR/$username/${username}_olcrtc.yaml"
            rm -f "$BASE_DIR/$username/${username}_olcrtc.uri"
            rm -f "$BASE_DIR/$username/${username}_olcrtc.png"
            rm -f "$BASE_DIR/$username/${username}_olcrtc.txt"
            echo -e "${GREEN}Конфигурация olcRTC удалена.${NC}"
            ;;
        vless)
            if [ -f "$VLESS_USERS_FILE" ]; then
                jq --arg user "$username" 'del(.[$user])' \
                  "$VLESS_USERS_FILE" > /tmp/vless_users.tmp && mv /tmp/vless_users.tmp "$VLESS_USERS_FILE"
                update_xray_config
            fi
            rm -f "$BASE_DIR/$username/${username}_vless.uri"
            rm -f "$BASE_DIR/$username/${username}_vless.png"
            echo -e "${GREEN}Конфигурация VLESS+XHTTP+REALITY удалена.${NC}"
            ;;
        troy)
            if [ -f "$TROJAN_USERS_FILE" ]; then
                jq --arg user "$username" 'del(.[$user])' \
                  "$TROJAN_USERS_FILE" > /tmp/trojan_users.tmp && mv /tmp/trojan_users.tmp "$TROJAN_USERS_FILE"
                update_trojango_config
                systemctl restart "$TROJAN_SERVICE"
            fi
            rm -f "$BASE_DIR/$username/${username}_troyan.json" "$BASE_DIR/$username/${username}_troyan.uri" "$BASE_DIR/$username/${username}_troyan.png"
            echo -e "${GREEN}Конфигурация Trojan удалена.${NC}"
            ;;
    esac

    echo -e "${GREEN}Готово! Конфигурация '$selected_name' для пользователя '$username' удалена.${NC}"
}

# --- ФУНКЦИИ ПРОТОКОЛОВ ---

add_hy2_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Введите имя пользователя: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_hy2.json" ]; then
        echo -e "${YELLOW}Hysteria 2 уже добавлен для '$username'.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Генерируем настройки Hysteria 2 для '$username'...${NC}"
    
    local password=$(openssl rand -hex 12)

    local server_port=$(yq '.listen' "$HY2_CONFIG" | tr -d ':"' | grep -oE '[0-9]+')
    [ -z "$server_port" ] && server_port=443

    local obfs_type=$(yq '.obfs.type' "$HY2_CONFIG" | tr -d '"')
    local obfs_pass=""
    if [ "$obfs_type" = "salamander" ]; then
        obfs_pass=$(yq '.obfs.salamander.password // .obfs.password' "$HY2_CONFIG" | tr -d '"')
    fi

    jq --arg user "$username" --arg pass "$password" \
      '.auth.userpass[$user] = $pass' \
      "$HY2_CONFIG" > /tmp/hy2_config.tmp && mv /tmp/hy2_config.tmp "$HY2_CONFIG"
    systemctl restart hysteria2

    local user_dir="$BASE_DIR/$username"
    local tag_name="nyx-hy2 - $username"
    local auth_str="${username}:${password}"

    jq -n \
      --arg tag_val "$tag_name" --arg server_val "$SERVER_DOMAIN" --argjson port_val "$server_port" \
      --arg pass_val "$auth_str" --arg obfs_type_val "$obfs_type" --arg obfs_pass_val "$obfs_pass" \
      '{
        outbounds: [
          {
            type: "hysteria2", tag: $tag_val, server: $server_val, server_port: $port_val
          } +
          (if $obfs_type_val != "" and $obfs_type_val != "null" and $obfs_pass_val != "" and $obfs_pass_val != "null" then
             { obfs: { type: $obfs_type_val, password: $obfs_pass_val } }
           else {} end) +
          {
            password: $pass_val,
            tls: { enabled: true, server_name: $server_val }
          }
        ]
      }' > "$user_dir/${username}_hy2_temp.json"

    jq . "$user_dir/${username}_hy2_temp.json" > "$user_dir/${username}_hy2.json"
    generate_qr "$(jq -c . "$user_dir/${username}_hy2_temp.json")" "$user_dir/${username}_hy2.png"
    rm "$user_dir/${username}_hy2_temp.json"
    echo -e "${GREEN}Готово! Конфиг и QR-код Hysteria 2 сохранены.${NC}"
}

add_awg_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Введите имя пользователя: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_awg.conf" ]; then
        echo -e "${YELLOW}AmneziaWG уже добавлен для '$username'.${NC}"; return 1; fi

    echo -e "${YELLOW}Генерируем настройки AmneziaWG для '$username'...${NC}"

    if [ ! -f "$AWG_CONFIG" ]; then
        echo -e "${RED}Конфиг AmneziaWG не найден по пути $AWG_CONFIG${NC}"
        return 1
    fi

    local client_priv=$(awg genkey)
    local client_pub=$(echo "$client_priv" | awg pubkey)
    local psk=$(awg genpsk)

    local ip_num=2
    while grep -qE "^\s*AllowedIPs\s*=\s*${AWG_SUBNET}\.${ip_num}/32" "$AWG_CONFIG"; do
        ((ip_num++))
        if [ $ip_num -gt 254 ]; then
            echo -e "${RED}Ошибка: В подсети ${AWG_SUBNET}.x закончились свободные IP-адреса!${NC}"
            return 1
        fi
    done
    local client_ip="${AWG_SUBNET}.${ip_num}/32"

    local server_priv=$(grep -E "^\s*PrivateKey" "$AWG_CONFIG" | head -1 | awk '{print $3}')
    local server_pub=$(echo "$server_priv" | awg pubkey)
    local server_port=$(grep -E "^\s*ListenPort" "$AWG_CONFIG" | awk '{print $3}')
    local awg_params=$(grep -E "^\s*(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I5|ContentPaddingAddition|RekeyAfterTime)" "$AWG_CONFIG" | sed 's/^\s*//')

    local peers_before peers_after
    peers_before=$(grep -c "^PublicKey" "$AWG_CONFIG")
    _sync_log "awg-add user=$username conf=$AWG_CONFIG peers_before=$peers_before ip=$client_ip"

    cat <<EOF >> "$AWG_CONFIG"

# Peer: $username
[Peer]
PublicKey = $client_pub
PresharedKey = $psk
AllowedIPs = $client_ip
EOF

    # The append is the whole point of this command, so confirm it landed rather
    # than reporting success and leaving the interface untouched.
    peers_after=$(grep -c "^PublicKey" "$AWG_CONFIG")
    if [ "$peers_after" -le "$peers_before" ]; then
        _sync_log "awg-add FAILED user=$username conf unchanged ($peers_before)"
        echo -e "${RED}Не удалось записать пира в $AWG_CONFIG — интерфейс НЕ изменён.${NC}" >&2
        return 1
    fi
    _sync_log "awg-add wrote user=$username peers_after=$peers_after"

    awg_apply_config "add_awg_user:$username"

    echo "$client_pub" > "$BASE_DIR/$username/.awg_pubkey"

    # H11: resolvers are a setting. Empty means "do not override the client's
    # DNS", which is the honest default for a self-hosted tunnel — silently
    # pointing every client at one resolver was a leak and a surprise.
    # AWG writes a plain resolver list here. For DoH/DoT the client app needs its
    # own setting, so this stays a plain list and the note goes in the manual.
    local dns_line=""
    [ -n "${AWG_CLIENT_DNS:-}" ] && dns_line="DNS = ${AWG_CLIENT_DNS}"
    # P2: 0.0.0.0/0 routes everything through the server. AWG_ALLOWED_IPS can
    # narrow it, e.g. to exclude RFC1918 so LAN traffic stays local.
    local allowed="${AWG_ALLOWED_IPS:-0.0.0.0/0, ::/0}"

    local client_conf="[Interface]
PrivateKey = $client_priv
Address = $client_ip
$dns_line
$awg_params

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = ${SERVER_DOMAIN}:${server_port}
AllowedIPs = $allowed
PersistentKeepalive = 25"

    echo "$client_conf" > "$BASE_DIR/$username/${username}_awg.conf"
    generate_qr "$client_conf" "$BASE_DIR/$username/${username}_awg.png"

    echo -e "${GREEN}Готово! AmneziaWG добавлен. IP клиента: $client_ip${NC}"
    echo -e "${GREEN}Конфиг и QR-код сохранены в папке $BASE_DIR/$username${NC}"
}

add_naive_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Введите имя пользователя: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_naive.json" ]; then
        echo -e "${YELLOW}NaiveProxy уже добавлен для '$username'.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Генерируем настройки NaiveProxy для '$username'...${NC}"

    if [ ! -f "$NAIVE_CONFIG" ]; then
        echo -e "${RED}Конфиг sing-box Naive не найден по пути $NAIVE_CONFIG${NC}"
        return 1
    fi

    local password=$(openssl rand -hex 12)
    local tag_name="nyx-naive - $username"

    # Добавляем пользователя в sing-box config.json
    jq --arg user "$username" --arg pass "$password" \
      '.inbounds[0].users += [{"username": $user, "password": $pass}]' \
      "$NAIVE_CONFIG" > /tmp/naive_config.tmp && mv /tmp/naive_config.tmp "$NAIVE_CONFIG"

    systemctl restart sing-box-naive

    jq -n \
      --arg tag_val "$tag_name" \
      --arg server_val "$SERVER_DOMAIN" \
      --argjson port_val "$NAIVE_PORT" \
      --arg user_val "$username" \
      --arg pass_val "$password" \
      '{
        outbounds: [
          {
            type: "naive",
            tag: $tag_val,
            server: $server_val,
            server_port: $port_val,
            username: $user_val,
            password: $pass_val,
            udp_over_tcp: true,
            tls: {
              enabled: true
            }
          }
        ]
      }' > "$BASE_DIR/$username/${username}_naive_temp.json"

    jq . "$BASE_DIR/$username/${username}_naive_temp.json" > "$BASE_DIR/$username/${username}_naive.json"
    generate_qr "$(jq -c . "$BASE_DIR/$username/${username}_naive_temp.json")" "$BASE_DIR/$username/${username}_naive.png"
    
    rm "$BASE_DIR/$username/${username}_naive_temp.json"

    echo -e "${GREEN}Готово! NaiveProxy добавлен.${NC}"
    echo -e "${GREEN}Конфиг (${username}_naive.json) и QR-код сохранены в папке $BASE_DIR/$username${NC}"
}

# Синхронизация всех naive-юзеров из proxy_users/*/*_naive.json → sing-box config.json
# Используется при миграции или если юзеры добавлялись через пanel напрямую
sync_naive_users() {
    echo -e "${YELLOW}Синхронизация naive-юзеров в sing-box...${NC}"

    if [ ! -d "$BASE_DIR" ]; then
        echo -e "${RED}Директория $BASE_DIR не найдена${NC}"
        return 1
    fi

    # Собираем всех юзеров из *_naive.json файлов
    local users_json="[]"
    for f in "$BASE_DIR"/*/*_naive.json; do
        [ -f "$f" ] || continue
        local user_pass
        user_pass=$(jq -r '.outbounds[] | select(.type == "naive") | "\(.username) \(.password)"' "$f" 2>/dev/null)
        if [ -n "$user_pass" ]; then
            local user=$(echo "$user_pass" | awk '{print $1}')
            local pass=$(echo "$user_pass" | awk '{print $2}')
            if [ -n "$user" ] && [ -n "$pass" ]; then
                users_json=$(echo "$users_json" | jq --arg u "$user" --arg p "$pass" '. + [{"username": $u, "password": $p}]')
                echo -e "  ${GREEN}+ $user${NC}"
            fi
        fi
    done

    local count=$(echo "$users_json" | jq 'length')
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}Не найдено ни одного naive-юзера${NC}"
        return 1
    fi

    echo -e "${GREEN}Найдено $count юзеров. Записываем в $NAIVE_CONFIG...${NC}"

    # Обновляем sing-box config — заменяем весь массив users
    jq --argjson users "$users_json" '.inbounds[0].users = $users' "$NAIVE_CONFIG" > /tmp/naive_config.tmp \
        && mv /tmp/naive_config.tmp "$NAIVE_CONFIG"

    systemctl restart sing-box-naive
    echo -e "${GREEN}sing-box перезапущен. Синхронизировано $count юзеров.${NC}"
}

add_mieru_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Введите имя пользователя: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    
    if [ -f "$BASE_DIR/$username/${username}_mieru.json" ]; then
        echo -e "${YELLOW}Mieru уже добавлен для '$username'.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Генерируем настройки Mieru для '$username'...${NC}"

    # 1. Генерация пароля
    local password=$(openssl rand -hex 8)

    # 2. Инициализируем persistent-конфиг Mieru если ещё нет
    init_mieru_config

    # 3. Добавляем пользователя в JSON-конфиг (с plaintext password)
    jq --arg name "$username" --arg pass "$password" \
      '.users += [{"name": $name, "password": $pass}]' \
      "$MIERU_CONFIG" > "${MIERU_CONFIG}.tmp" && mv "${MIERU_CONFIG}.tmp" "$MIERU_CONFIG"

    # 4. Применяем конфиг в mita и перезапускаем (stop + start вместо reload)
    apply_mieru_config

    # 5. Генерируем клиентский JSON для NEKOBOX (sing-box формат, для enfein/mbox)
    jq -n \
      --arg tag_val "nyx-mieru - $username" \
      --arg server_val "$SERVER_DOMAIN" \
      --argjson port_val 444 \
      --arg user_val "$username" \
      --arg pass_val "$password" \
      '{
        outbounds: [
          {
            type: "mieru",
            tag: $tag_val,
            server: $server_val,
            server_port: $port_val,
            transport: "TCP",
            username: $user_val,
            password: $pass_val
          }
        ]
      }' > "$BASE_DIR/$username/${username}_mieru.json"

    # 6. Генерируем официальный JSON для mieru-клиента (формат mieru apply config)
    jq -n \
      --arg server_ip "$MIERU_IP" \
      --arg server_domain "$SERVER_DOMAIN" \
      --arg port_range "$MIERU_PORTS" \
      --arg user_val "$username" \
      --arg pass_val "$password" \
      --arg tag_val "nyx-mieru - $username" \
      '{
        activeProfile: "default",
        socks5Port: 1080,
        loggingLevel: "INFO",
        profiles: [
          {
            profileName: $tag_val,
            user: {
              name: $user_val,
              password: $pass_val
            },
            servers: [
              {
                ipAddress: $server_ip,
                domainName: $server_domain,
                portBindings: [
                  {
                    portRange: $port_range,
                    protocol: "TCP"
                  }
                ]
              }
            ]
          }
        ]
      }' > "$BASE_DIR/$username/${username}_mieru_standalone.json"

    # 7. Генерируем текстовый файл с параметрами для ручного ввода в NekoBox
    cat > "$BASE_DIR/$username/${username}_nekobox.txt" << EOF
=== NekoBox Mieru (ручной ввод) ===
Сервер (serverAddress): $SERVER_DOMAIN
Порт (serverPort): 444
Протокол (protocol): TCP
Имя (username): $username
Пароль (password): $password
EOF

    # 8. Генерируем QR-код из sing-box формата
    generate_qr "$(jq -c . "$BASE_DIR/$username/${username}_mieru.json")" "$BASE_DIR/$username/${username}_mieru.png"

    echo -e "${GREEN}Готово! Mieru добавлен.${NC}"
    echo -e "${GREEN}• ${username}_mieru.json — sing-box конфиг${NC}"
    echo -e "${GREEN}• ${username}_mieru_standalone.json — официальный mieru-клиент${NC}"
    echo -e "${GREEN}• ${username}_nekobox.txt — для ручного ввода в NekoBox${NC}"
}

add_olcrtc_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Введите имя пользователя: " username; fi
    if ! check_user_exists "$username"; then return 1; fi

    if [ -f "$BASE_DIR/$username/${username}_olcrtc.json" ]; then
        echo -e "${YELLOW}olcRTC уже добавлен для '$username'.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Генерируем настройки olcRTC для '$username'...${NC}"

    local password=$(openssl rand -hex 12)

    # Создаем users.json если нет или он битый
    mkdir -p "$(dirname "$OLRTC_USERS_FILE")"
    python3 -c "import json; f='$OLRTC_USERS_FILE'; open(f,'a').close(); json.load(open(f))" 2>/dev/null || echo '{}' > "$OLRTC_USERS_FILE"

    # Добавляем пользователя в users.json
    jq --arg user "$username" --arg pass "$password" \
      '.[$user] = $pass' \
      "$OLRTC_USERS_FILE" > /tmp/olcrtc_users.tmp && mv /tmp/olcrtc_users.tmp "$OLRTC_USERS_FILE"

    # Генерируем клиентский JSON-конфиг
    cat > "$BASE_DIR/$username/${username}_olcrtc.json" << OLRTC_EOF
{
  "storage_id": "olcboxme-main",
  "name": "NYX Main",
  "endpoint": {
    "room_id": "${OLRTC_ROOM_URL}",
    "key": "${OLRTC_CRYPTO_KEY}"
  },
  "auth_provider": "jitsi",
  "transport": {
    "type": "datachannel"
  },
  "claims_user": "${username}",
  "claims_pass": "${password}"
}
OLRTC_EOF

    # olcbox URI
    local olcrtc_uri="olcrtc://jitsi?datachannel&user=${username}&pass=${password}@${OLRTC_ROOM_URL}#${OLRTC_CRYPTO_KEY}\$nyx-olcrtc - ${username}"
    echo "$olcrtc_uri" > "$BASE_DIR/$username/${username}_olcrtc.uri"

    # Текстовый файл с параметрами
    cat > "$BASE_DIR/$username/${username}_olcrtc.txt" << OLRTC_TXT
=== olcRTC — параметры подключения ===
Сервер ICE: ws://${SERVER_DOMAIN}:30001
Комната Jitsi: $OLRTC_ROOM_URL
Ключ шифрования: $OLRTC_CRYPTO_KEY
Имя пользователя: $username
Пароль: $password
SOCKS5: 127.0.0.1:1082

olcbox URI: $olcrtc_uri
OLRTC_TXT

    # QR-код из olcbox URI
    generate_qr "$olcrtc_uri" "$BASE_DIR/$username/${username}_olcrtc.png"

    echo -e "${GREEN}Готово! olcRTC добавлен.${NC}"
    echo -e "${GREEN}• ${username}_olcrtc.json — клиентский конфиг${NC}"
    echo -e "${GREEN}• ${username}_olcrtc.uri — olcbox URI${NC}"
    echo -e "${GREEN}• ${username}_olcrtc.txt — все параметры${NC}"
    echo -e "${GREEN}• ${username}_olcrtc.png — QR-код URI${NC}"
}

# --- VLESS+XHTTP+REALITY ---
update_xray_config() {
    if [ ! -f "$XRAY_CONFIG" ] || [ ! -f "$VLESS_USERS_FILE" ]; then return 1; fi
    # Writes the durable copy, then applies to the live instance over the gRPC
    # API. The old code ended in `systemctl restart $XRAY_SERVICE`, which dropped
    # every connected VLESS client on every user change.
    xray_apply_users "$VLESS_USERS_FILE" "$XRAY_CONFIG" "$XRAY_SERVICE" "update_xray_config"
}

add_vless_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Введите имя пользователя: " username; fi
    if ! check_user_exists "$username"; then return 1; fi

    if [ -f "$BASE_DIR/$username/${username}_vless.uri" ]; then
        echo -e "${YELLOW}VLESS уже добавлен для '$username'.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Генерируем настройки VLESS+XHTTP+REALITY для '$username'...${NC}"

    # Создаем users.json если нет
    mkdir -p "$(dirname "$VLESS_USERS_FILE")"
    if [ ! -f "$VLESS_USERS_FILE" ]; then
        echo '{}' > "$VLESS_USERS_FILE"
    fi

    # Генерируем UUID
    local uuid
    uuid=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid || openssl rand -hex 16)

    # Добавляем пользователя в users.json
    jq --arg user "$username" --arg uuid "$uuid" \
      '.[$user] = $uuid' \
      "$VLESS_USERS_FILE" > /tmp/vless_users.tmp && mv /tmp/vless_users.tmp "$VLESS_USERS_FILE"

    # Обновляем конфиг xray и перезапускаем
    update_xray_config

    # Генерируем vless:// URI
    local link="vless://${uuid}@${VLESS_HOST}:${VLESS_PORT}?security=reality&type=xhttp&path=${VLESS_PATH}&sni=${VLESS_SNI}&fp=firefox&pbk=${VLESS_PUBLIC_KEY}&sid=${VLESS_SHORT_ID}&spx=%2Fdns-query%2F#${username}"
    echo "$link" > "$BASE_DIR/$username/${username}_vless.uri"

    # QR-код из URI
    generate_qr "$link" "$BASE_DIR/$username/${username}_vless.png"

    echo -e "${GREEN}Готово! VLESS+XHTTP+REALITY добавлен.${NC}"
    echo -e "${GREEN}• ${username}_vless.uri — vless:// ссылка${NC}"
    echo -e "${GREEN}• ${username}_vless.png — QR-код${NC}"
}

# --- REALITY mode: normal (1.1.1.1) <-> whitelist (белый домен) ---
# Затрагивает только VLESS+XHTTP+REALITY (xray). Trojan/hy2/awg/naive/mieru/olcrtc — НЕ затрагиваются.
REALITY_NORMAL_TARGET="1.1.1.1:443"
REALITY_NORMAL_SNI="1.1.1.1"
REALITY_WL_TARGET="sun6-22.userapi.com:443"
REALITY_WL_SNI="sun6-22.userapi.com"
REALITY_WL_SERVER="stats.vk-portal.net"

reality_status() {
    if [ ! -f "$XRAY_CONFIG" ]; then
        echo "mode=unknown"
        echo "target="
        echo "sni="
        echo "affected=vless"
        echo "error=xray config not found: $XRAY_CONFIG"
        return 1
    fi
    local target
    target=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.target // empty' "$XRAY_CONFIG" 2>/dev/null | head -1)
    local mode="unknown"
    case "$target" in
        "$REALITY_NORMAL_TARGET") mode="normal" ;;
        "$REALITY_WL_TARGET") mode="whitelist" ;;
    esac
    echo "mode=$mode"
    echo "target=$target"
    echo "sni=$REALITY_NORMAL_SNI"
    echo "affected=vless"
}

set_reality_mode() {
    local mode=$1
    if [ -z "$mode" ]; then
        echo "Usage: set_reality_mode {normal|whitelist}"
        return 1
    fi
    if [ ! -f "$XRAY_CONFIG" ]; then
        echo -e "${RED}Xray config not found: $XRAY_CONFIG${NC}"
        return 1
    fi
    load_server_settings
    local server_domain
    server_domain=$(grep -ohE '[A-Za-z0-9*.-]+\.example\.com' /etc/caddy/Caddyfile 2>/dev/null | head -1)
    [ -z "$server_domain" ] && server_domain="$SERVER_DOMAIN"

    local new_target new_sni
    case "$mode" in
        normal)
            new_target="$REALITY_NORMAL_TARGET"
            new_sni="$REALITY_NORMAL_SNI"
            jq --arg t "$new_target" --arg sn1 "" --arg sn2 "$REALITY_NORMAL_SNI" --arg sn3 "$server_domain" \
              '(.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.target) = $t |
               (.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames) = [$sn1, $sn2, $sn3]' \
              "$XRAY_CONFIG" > /tmp/xray_reality.tmp && mv /tmp/xray_reality.tmp "$XRAY_CONFIG"
            ;;
        whitelist)
            new_target="$REALITY_WL_TARGET"
            new_sni="$REALITY_WL_SNI"
            jq --arg t "$new_target" --arg sn1 "$REALITY_WL_SNI" --arg sn2 "$REALITY_WL_SERVER" --arg sn3 "$server_domain" \
              '(.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.target) = $t |
               (.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames) = [$sn1, $sn2, $sn3]' \
              "$XRAY_CONFIG" > /tmp/xray_reality.tmp && mv /tmp/xray_reality.tmp "$XRAY_CONFIG"
            ;;
        *)
            echo -e "${RED}Unknown mode: $mode (normal|whitelist)${NC}"
            return 1
            ;;
    esac

    # Пересобираем все vless:// URI (актуальные pbk/sid/sni) + QR
    sync_vless_uris

    systemctl restart "$XRAY_SERVICE"
    echo -e "${GREEN}REALITY mode -> '$mode' (target=$new_target, sni=$new_sni). vless URIs updated via sync_vless_uris${NC}"
}

# Пересобирает все vless:// URI под актуальный серверный конфиг:
# pbk (из текущего privateKey), sid (shortIds[0]), sni (из target), путь, порт, host.
sync_vless_uris() {
    load_server_settings
    local target sni updated=0
    target=$(jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.target // empty' "$XRAY_CONFIG" 2>/dev/null | head -1)
    sni="${target%:*}"
    [ -z "$sni" ] && sni="$VLESS_SNI"
    local f user uuid link
    for f in "$BASE_DIR"/*/*_vless.uri; do
        [ -f "$f" ] || continue
        user=$(basename "$f" _vless.uri)
        uuid=$(grep -oE 'vless://[0-9a-f-]+' "$f" | head -1 | sed 's/vless:\/\///')
        [ -z "$uuid" ] && continue
        link="vless://${uuid}@${VLESS_HOST}:${VLESS_PORT}?security=reality&type=xhttp&path=${VLESS_PATH}&sni=${sni}&fp=firefox&pbk=${VLESS_PUBLIC_KEY}&sid=${VLESS_SHORT_ID}&spx=%2Fdns-query%2F#${user}"
        echo "$link" > "$f"
        generate_qr "$link" "${f%.uri}.png" 2>/dev/null
        updated=$((updated+1))
    done
    echo -e "${GREEN}vless URIs synced: $updated (sni=$sni, pbk=$VLESS_PUBLIC_KEY, sid=$VLESS_SHORT_ID)${NC}"
}

# --- Trojan ---
update_trojango_config() {
    python3 -c "
import json
config_file = '/etc/trojan-go/config.json'
users_file = '$TROJAN_USERS_FILE'

passwords = []
try:
    with open(users_file) as f:
        udict = json.load(f)
        passwords = list(udict.values())
except:
    pass

with open(config_file) as f:
    cfg = json.load(f)

cfg['password'] = passwords

with open(config_file, 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null
}

add_trojan_user() {
    local username=$1
    if [ -z "$username" ]; then read -p "Введите имя пользователя: " username; fi
    if ! check_user_exists "$username"; then return 1; fi
    if [ -f "$BASE_DIR/$username/${username}_troyan.json" ]; then
        echo -e "${YELLOW}Trojan уже добавлен для '$username'.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Генерируем настройки Trojan для '$username'...${NC}"

    local password=$(openssl rand -hex 12)
    mkdir -p "$(dirname "$TROJAN_USERS_FILE")"
    if [ ! -f "$TROJAN_USERS_FILE" ]; then echo '{}' > "$TROJAN_USERS_FILE"; fi
    jq --arg user "$username" --arg pass "$password" '.[$user] = $pass' "$TROJAN_USERS_FILE" > /tmp/trojan_users.tmp && mv /tmp/trojan_users.tmp "$TROJAN_USERS_FILE"
    update_trojango_config
    systemctl restart "$TROJAN_SERVICE"

    local tag_name="nyx-trojan - $username"
    jq -n --arg tag "$tag_name" --arg srv "$SERVER_DOMAIN" --argjson port "$TROJAN_PORT" --arg pass "$password" \
      '{"outbounds": [{"type": "trojan", "tag": $tag, "server": $srv, "server_port": $port, "password": $pass, "tls": {"enabled": true, "server_name": $srv}}]}' \
      > "$BASE_DIR/$username/${username}_troyan.json"
    local link="trojan://${password}@${SERVER_DOMAIN}:${TROJAN_PORT}?security=tls&sni=${SERVER_DOMAIN}&type=tcp&headerType=none#${username}"
    echo "$link" > "$BASE_DIR/$username/${username}_troyan.uri"
    generate_qr "$link" "$BASE_DIR/$username/${username}_troyan.png"
    echo -e "${GREEN}Готово! Trojan добавлен. Конфиг и QR сохранены.${NC}"
}

# --- ГЛАВНОЕ МЕНЮ ---
show_menu() {
    clear
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "${GREEN}      🚀 ПРОКСИ-МЕНЕДЖЕР (v0.8) 🚀${NC}"
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "${WHITE}1. Добавить пользователя${NC}"
    echo -e "${WHITE}2. Удалить пользователя${NC}"
    echo -e "${WHITE}3. Список пользователей${NC}"
    echo -e "${WHITE}4. Удалить конфигурацию протокола${NC}"
    echo -e "${CYAN}-----------------------------------------${NC}"
    echo -e "${GREEN}5. Добавить Hysteria 2 пользователю${NC}"
    echo -e "${GREEN}6. Добавить AmneziaWG пользователю${NC}"
    echo -e "${GREEN}7. Добавить NaiveProxy пользователю${NC}"
    echo -e "${GREEN}8. Добавить Mieru пользователю${NC}"
    echo -e "${GREEN}9. Добавить olcRTC пользователю${NC}"
    echo -e "${GREEN}10. Добавить VLESS+XHTTP+REALITY пользователю${NC}"
    echo -e "${GREEN}11. Добавить Trojan пользователю${NC}"
    echo -e "${CYAN}-----------------------------------------${NC}"
    echo -e "${RED}0. Выход${NC}"
    echo -e "${YELLOW}=========================================${NC}"
    
    local prompt=$(echo -e "${GREEN}Выберите действие: ${NC}")
    read -p "$prompt" choice
}

main_loop() {
    while true; do
        show_menu
        case $choice in
            1) add_user ;;
            2) del_user ;;
            3) list_users ;;
            4) remove_protocol ;;  
            5) add_hy2_user ;;
            6) add_awg_user ;;
            7) add_naive_user ;;
            8) add_mieru_user ;;
            9) add_olcrtc_user ;;
            10) add_vless_user ;;
            11) add_trojan_user ;;
            0) exit 0 ;;
            *) echo -e "${RED}Неверный выбор.${NC}" ;;
        esac
        read -p "Нажмите Enter для продолжения..."
    done
}

# --- ЗАПУСК / CLI ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    init
    if [ $# -gt 0 ]; then
        case "$1" in
            add_user|del_user|add_hy2_user|add_awg_user|add_naive_user|add_mieru_user|add_olcrtc_user|add_vless_user|add_trojan_user)
                "$1" "$2"
                # Root wrote these; the panel has to own them.
                _fix_state_owner
                ;;
            sync_naive_users|sync_naive)
                sync_naive_users ;;
            list_users|list)
                list_users ;;
            remove_protocol)
                remove_protocol "$3" "$2"
                _fix_state_owner ;;
            set_reality_mode)
                set_reality_mode "$2" ;;
            sync_vless_uris)
                sync_vless_uris ;;
            reality_status)
                reality_status ;;
            update_xray_config|reconcile_xray)
                # Re-push /etc/xray/users.json into the running xray and into the
                # config file. Manual recovery after editing users.json by hand.
                update_xray_config ;;
            sync_awg|reconcile_awg)
                # Force a reconcile of the AmneziaWG interface from its config
                # file. Useful after a manual edit and as the non-interactive
                # entry point for testing awg_apply_config.
                awg_apply_config "${2:-manual}" ;;
            revoke_user|restore_user|expire_check)
                if declare -F "nyx_$1" >/dev/null 2>&1; then
                    nyx_$1 "$2"
                else
                    echo "revoke library not loaded" >&2; exit 1
                fi ;;
            *)
                echo "Usage: $0 {add_user|del_user|list_users|remove_protocol|sync_naive_users|add_hy2_user|add_awg_user|add_naive_user|add_mieru_user|add_olcrtc_user|add_vless_user|add_trojan_user|set_reality_mode|sync_vless_uris|reality_status|sync_awg|update_xray_config|revoke_user|restore_user|expire_check} [username] [protocol]"
                exit 1 ;;
        esac
        exit $?
    fi
    main_loop
fi

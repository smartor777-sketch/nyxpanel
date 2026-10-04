#!/bin/bash
# Regression test for the AmneziaWG peer-stripping rule in del_user and
# remove_protocol.
#
# This rule was wrong and the failure was silent: it removed only the
# "# Peer: <name>" comment and left PublicKey/PresharedKey/AllowedIPs in place.
# The reconcile then saw the peer still in the file, removed nothing, and the
# user could not be deleted at all — while the panel reported success. A bare
# "[Peer]" header was left behind each time.
#
# The test extracts the awk program straight out of proxy_manager.sh, so it
# cannot drift away from the implementation, and checks it against a config with
# a peer in the middle and at the end.
set -u

MGR=${1:-bin/proxy_manager.sh}
fails=0
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

if [ ! -f "$MGR" ]; then
    echo "  FAIL  $MGR not found"
    exit 1
fi

# --- both sites must use the same rule ---------------------------------------
mapfile -t PROGRAMS < <(
    sed -n "/awk -v user=\"\$username\" '/,/^[[:space:]]*' \"\\\$AWG_CONFIG\"/p" "$MGR" \
        | sed -e "/awk -v user=/d" -e "/' \"\\\$AWG_CONFIG\"/d" -e 's/^[[:space:]]*//'
)
if [ "${#PROGRAMS[@]}" -lt 4 ]; then
    bad "found ${#PROGRAMS[@]} rule lines, expected 4 (two sites)"
else
    ok "both call sites carry a four-line rule"
fi

RULE=$(printf '%s\n' "${PROGRAMS[@]:0:4}")

# Both sites must be identical, or a future fix will only reach one of them.
SITE1=$(printf '%s\n' "${PROGRAMS[@]:0:4}")
SITE2=$(printf '%s\n' "${PROGRAMS[@]:4:4}")
if [ "$SITE1" = "$SITE2" ]; then
    ok "del_user and remove_protocol use the same rule"
else
    bad "the two sites differ:
  del_user:
$SITE1
  remove_protocol:
$SITE2"
fi

# --- behaviour ---------------------------------------------------------------
CONF=$(mktemp)
cat > "$CONF" <<'EOF'
[Interface]
PrivateKey = srvkey
Address = 10.9.9.1/24
ListenPort = 51820

[Peer]
PublicKey = AAA=
PresharedKey = aaa=
AllowedIPs = 10.9.9.2/32

# Peer: alice
[Peer]
PublicKey = BOB=
PresharedKey = bbb=
AllowedIPs = 10.9.9.3/32

# Peer: carol
[Peer]
PublicKey = CCCC=
PresharedKey = ccc=
AllowedIPs = 10.9.9.4/32
EOF

strip() {
    awk -v user="$1" "$RULE" "$CONF"
}
keys() { grep '^PublicKey' | cut -d= -f2 | tr -d ' ' | tr '\n' ' '; }

check_keys() {
    local user=$1 want=$2 got
    got=$(strip "$user" | keys)
    if [ "$got" = "$want" ]; then
        ok "remove '$user' leaves: $got"
    else
        bad "remove '$user' left: [$got]  expected: [$want]"
    fi
}

check_keys alice "AAA CCCC "     # a peer in the middle
check_keys carol "AAA BOB "      # the last peer
check_keys nobody "AAA BOB CCCC " # an unknown user changes nothing

# --- structural properties the old rule broke --------------------------------
if strip alice | grep -q 'BOB'; then
    bad "the removed peer's PublicKey is still in the file"
else
    ok "the removed peer's PublicKey is gone"
fi
if strip alice | grep -q '# Peer: alice'; then
    bad "the removed peer's comment is still in the file"
else
    ok "the removed peer's comment is gone"
fi
# The old rule left an orphaned header, producing a bare [Peer] with no keys.
if strip alice | awk '/^\[Peer\]$/{h=NR} h && NR==h+1 && !/^PublicKey/{found=1} END{exit found}'; then
    ok "no orphaned [Peer] header is left behind"
else
    bad "an orphaned [Peer] header was left behind"
fi
# Every surviving [Peer] must still be followed by its keys.
if strip alice | grep -c '^\[Peer\]$' | grep -qx "$(strip alice | grep -c '^PublicKey')"; then
    ok "every [Peer] header still has its keys"
else
    bad "a [Peer] header lost its keys"
fi

# --- and the interface stanza must survive -----------------------------------
if strip alice | grep -q '^\[Interface\]$' && strip alice | grep -q '^ListenPort'; then
    ok "the [Interface] stanza is untouched"
else
    bad "the [Interface] stanza was damaged"
fi

rm -f "$CONF"
echo
if [ "$fails" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; fi
exit "$fails"
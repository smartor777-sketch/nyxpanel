#!/bin/bash
# Regression test for the AmneziaWG client-config parameter list.
#
# AmneziaWG 3.1 adds HeaderProtectionKey, RandomTrailers, DisableCookies,
# I2-I4 and the timing parameters. They are interface-level settings and must
# be copied into every client profile; forgetting one produces a config that
# silently fails to handshake. This test extracts the grep pattern straight
# out of proxy_manager.sh so it cannot drift away from the implementation.
set -u

MGR=${1:-bin/proxy_manager.sh}
fails=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

if [ ! -f "$MGR" ]; then
    echo "  FAIL  $MGR not found"
    exit 1
fi

LINE=$(grep -n 'local awg_params=' "$MGR" | head -1)
if [ -z "$LINE" ]; then
    bad "awg_params assignment not found in $MGR"
    exit 1
fi
ok "awg_params assignment found"

PATTERN=$(printf '%s\n' "$LINE" | sed -E 's/.*grep -E "([^"]+)".*/\1/')
if [ -z "$PATTERN" ] || [ "$PATTERN" = "$LINE" ]; then
    bad "could not extract the grep pattern"
    exit 1
fi

# Exact token comparison: split on '|' after removing the ^\s*( ... ) wrapper.
TOKENS=$(printf '%s' "$PATTERN" | sed -E 's/^\^\\s\*\(//; s/\)$//' | tr '|' '\n')

has_token() {
    printf '%s\n' "$TOKENS" | grep -qx -- "$1"
}

# 3.1 wire-format parameters: must match the server.
for key in HeaderProtectionKey RandomTrailers DisableCookies S1 S2 S3 S4 H1 H2 H3 H4; do
    if has_token "$key"; then ok "copies $key"; else bad "missing $key"; fi
done

# 3.1 client-side parameters: copied for consistency.
for key in I1 I2 I3 I4 I5 ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts Jc Jmin Jmax; do
    if has_token "$key"; then ok "copies $key"; else bad "missing $key"; fi
done

# Server-only / peer-only settings must not leak into the client [Interface].
for key in PrivateKey ListenPort Address MTU PostUp PostDown PresharedKey PublicKey AllowedIPs; do
    if has_token "$key"; then bad "must not copy $key"; else ok "does not copy $key"; fi
done

# --- behaviour on a realistic 3.1 config ------------------------------------
CONF=$(mktemp)
cat > "$CONF" <<'EOF'
[Interface]
PrivateKey = server-private-key
Address = 10.20.20.1/24
ListenPort = 39743
MTU = 1280
HeaderProtectionKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Jc = 5
Jmin = 50
Jmax = 200
S1 = 64
S2 = 78
S3 = 48
S4 = 32
H1 = 1000000-1100000
H2 = 2000000-2100000
H3 = 3000000-3100000
H4 = 4000000-4100000
I1 = <r 64>
I2 = <rd 8>
I3 = <r 32>
I4 = <rd 4>
I5 = <r 16>
ContentPaddingAddition = 8-32
RekeyAfterTime = 100-140
RekeyTimeout = 5-10
RejectAfterTime = 180-200
KeepaliveTimeout = 10-15
MaxHandshakeAttempts = 18-20
RandomTrailers = on
DisableCookies = on
PostUp = sysctl -w net.ipv4.ip_forward=1
PostDown = true

[Peer]
PublicKey = client-public-key
PresharedKey = psk
AllowedIPs = 10.20.20.2/32
EOF

OUT=$(grep -E "$PATTERN" "$CONF" | sed 's/^\s*//')
for line in \
    'HeaderProtectionKey =' \
    'RandomTrailers = on' \
    'DisableCookies = on' \
    'I2 = <rd 8>' \
    'I3 = <r 32>' \
    'I4 = <rd 4>' \
    'RekeyTimeout = 5-10' \
    'MaxHandshakeAttempts = 18-20'; do
    if printf '%s\n' "$OUT" | grep -qF -- "$line"; then
        ok "generated config keeps '$line'"
    else
        bad "generated config lost '$line'"
    fi
done
for line in 'PrivateKey' 'ListenPort' 'MTU =' 'PostUp' 'PostDown' 'PresharedKey' 'AllowedIPs'; do
    if printf '%s\n' "$OUT" | grep -qF -- "$line"; then
        bad "generated config leaked '$line'"
    else
        ok "generated config excludes '$line'"
    fi
done
rm -f "$CONF"

echo
if [ "$fails" -eq 0 ]; then
    echo "  All AmneziaWG 3.1 parameter tests passed."
else
    echo "  $fails test(s) failed."
    exit 1
fi

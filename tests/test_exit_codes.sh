#!/bin/bash
# A command that does its job and exits non-zero is worse than one that fails
# loudly: the panel's call_script() maps a non-zero exit to "error", so a working
# operation gets reported as broken.
#
# Found on prod: list_users() printed the whole list and exited 1, because the
# loop's status came from the last `[ -f … ] && echo` of the last user in the
# registry. user08 has only AmneziaWG, so the Trojan check failed and the exit
# code was 1. On the dev stand the last user happened to have every protocol, so
# it returned 0 there and the bug was invisible.
set -u

MGR=${1:-bin/proxy_manager.sh}
fails=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s  %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

[ -f "$MGR" ] || { echo "  FAIL: $MGR not found"; exit 1; }

# --- every read-only command must exit 0 -----------------------------------
export NYX_ENV=${NYX_ENV:-/etc/nyxpanel/proxy.env}

# list_users, isolated: point BASE_DIR and REGISTRY_FILE at a fixture whose last
# entry lacks the protocol checked last.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/users/first" "$T/users/last"
touch "$T/users/first/first_hy2.json" "$T/users/first/first_awg.conf" \
      "$T/users/first/first_vless.uri" \
      "$T/users/last/last_awg.conf"
printf 'first\nlast\n' > "$T/registry"

run_list() {
    # shellcheck disable=SC1090
    BASE_DIR="$T/users" REGISTRY_FILE="$T/registry" \
        bash -c "source <(sed -n '/^list_users()/,/^}/p' '$MGR'); list_users" 2>/dev/null
}

OUT=$(run_list)
RC=$?
if [ "$RC" -eq 0 ]; then
    ok "list_users exits 0 when the last user lacks the last protocol checked"
else
    bad "list_users exits 0 when the last user lacks the last protocol checked" "rc=$RC"
fi

for want in first last; do
    if printf '%s' "$OUT" | grep -q "$want"; then
        ok "list_users printed '$want'"
    else
        bad "list_users printed '$want'"
    fi
done
if printf '%s' "$OUT" | grep -q "Hysteria 2" && ! printf '%s' "$OUT" | grep -q "Trojan"; then
    ok "protocols are reported per user, not assumed"
else
    bad "protocols are reported per user, not assumed"
fi

# --- the explicit return must be there, not an accident of the data ---------
if sed -n '/^list_users()/,/^}/p' "$MGR" | grep -q 'return 0'; then
    ok "list_users has an explicit 'return 0'"
else
    bad "list_users has an explicit 'return 0'" "the exit code depends on the last user again"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; fi
exit "$fails"

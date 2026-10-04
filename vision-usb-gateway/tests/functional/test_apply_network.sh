#!/usr/bin/env bash
set -euo pipefail

# apply-network.sh applies network.json (DHCP or a static IPv4 for eth0) to
# NetworkManager — at boot, on a re-plug of a static-IP unit and, out of band,
# after a WebUI change. What must hold:
# - only ever the interface's own client profile is changed — never the
#   direct-link DHCP server (citostore-direct) or the DHCP probe, which the
#   WebUI used to rewrite when they were the active profile;
# - at boot it waits for NetworkManager to create the profile;
# - no cable: the profile is set, nothing is activated, no failure;
# - DHCP that nothing answers hands over to mdns-apply-mode (redecide), so a
#   laptop link is served again without a reboot;
# - every modify is --temporary (network.json is the persistent truth).
#
# nmcli is a stateful stub (profiles + active connections in files); the
# interface is "lo" when a cable is wanted (its carrier reads 1) and "tst0"
# when not (no such interface: no carrier). Needs root + python3:
#   docker run --rm -v "$PWD:/gw:ro" python:3.11-slim-bookworm \
#     bash /gw/tests/functional/test_apply_network.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)

if [[ $(id -u) -ne 0 ]]; then
  echo "must run as root (apply-network.sh requires it)" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# profiles: "name|type|ifname|method" per line; active: "name:dev" per line.
cat > "$TMP/bin/nmcli" <<EOF
#!/bin/bash
T="$TMP"
args="\$*"
case "\$args" in
  "-t -f NAME,DEVICE connection show --active")
    cat "\$T/active"; exit 0 ;;
  "-t -f NAME,TYPE connection show")
    n=\$(( \$(cat "\$T/lists" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$T/lists"
    (( n >= \$(cat "\$T/profiles_from") )) || exit 0
    while IFS='|' read -r name type _ _; do echo "\$name:\$type"; done < "\$T/profiles"; exit 0 ;;
  "-g connection.interface-name connection show "*)
    awk -F'|' -v n="\${args#-g connection.interface-name connection show }" '\$1==n{print \$3}' "\$T/profiles"; exit 0 ;;
  "-g ipv4.method connection show "*)
    awk -F'|' -v n="\${args#-g ipv4.method connection show }" '\$1==n{print \$4}' "\$T/profiles"; exit 0 ;;
esac
echo "\$args" >> "\$T/calls"
if [[ "\$1 \$2 \$3" == "connection modify --temporary" ]]; then
  [[ -f "\$T/modify_err" ]] && { cat "\$T/modify_err" >&2; exit 2; }
  name=\$4; shift 4
  while (( \$# )); do
    [[ "\$1" == ipv4.method ]] && awk -F'|' -v OFS='|' -v n="\$name" -v m="\$2" '\$1==n{\$4=m}1' "\$T/profiles" > "\$T/p" && mv "\$T/p" "\$T/profiles"
    shift 2
  done
  exit 0
fi
if [[ "\$1 \$2 \$3 \$4" == "-w 20 connection up" ]]; then
  rc=\$(cat "\$T/up_rc"); ((rc == 0)) || { echo "Error: activation failed" >&2; exit "\$rc"; }
  dev=\$(awk -F'|' -v n="\$5" '\$1==n{print \$3}' "\$T/profiles")
  grep -v ":\$dev\\\$" "\$T/active" > "\$T/a" || true; echo "\$5:\$dev" >> "\$T/a"; mv "\$T/a" "\$T/active"
  exit 0
fi
exit 0
EOF
# mdns-apply-mode.sh redecide: needs avahi-set-host-name to run at all, and
# spawns its carrier wait with systemd-run.
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/avahi-set-host-name"
printf '#!/bin/sh\nexit 3\n' > "$TMP/bin/systemctl"
printf '#!/bin/sh\necho "systemd-run $*" >> %s/calls\n' "$TMP" > "$TMP/bin/systemd-run"
chmod +x "$TMP/bin/"*

DIRECT='citostore-direct|802-3-ethernet|lo|shared'
PROBE='citostore-probe|802-3-ethernet|lo|auto'
AOI='vision-eth1|802-3-ethernet|eth1|manual'

# One case = fresh state; prints "rc=<n> calls=<...>". The result for the
# WebUI is left in $TMP/result.json.
run_case() {  # <network.json or "-"> <profiles ("\n"-separated)> <active ("\n"-separated)> [up rc] [list call that first shows profiles] [wait]
  rm -f "$TMP/calls" "$TMP/lists" "$TMP/state.json" "$TMP/result.json" "$TMP/modify_err"
  [[ "$1" == "-" ]] || printf '%s' "$1" > "$TMP/state.json"
  printf '%b\n' "$2" | grep -v '^$' > "$TMP/profiles" || true
  printf '%b\n' "$3" | grep -v '^$' > "$TMP/active" || true
  echo "${4:-0}" > "$TMP/up_rc"
  echo "${5:-1}" > "$TMP/profiles_from"
  [[ -n "${MODIFY_ERR:-}" ]] && echo "$MODIFY_ERR" > "$TMP/modify_err"
  local rc=0
  PATH="$TMP/bin:$PATH" NETWORK_STATE_FILE="$TMP/state.json" NETWORK_RESULT_FILE="$TMP/result.json" \
    CONF_FILE=/nonexistent APPLY_NETWORK_WAIT_SEC="${6:-5}" \
    bash "$GW/scripts/apply-network.sh" >/dev/null 2>&1 || rc=$?
  echo "rc=$rc calls=$(cat "$TMP/calls" 2>/dev/null | tr '\n' ';' || true)"
}
result() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(("ok " if r["ok"] else "FAIL ") + r["message"])' "$TMP/result.json"; }

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }
has() { if [[ "$2" == *"$3"* ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 ('$2' lacks '$3')"; fail=1; fi; }

net() { printf '{"interface": "%s", "method": "%s", "address": "%s", "prefix": "%s", "gateway": "", "dns": ""}' "$@"; }
STATIC_LO=$(net lo manual 192.168.5.20 24)
STATIC_NC=$(net tst0 manual 192.168.5.20 24)
DHCP_LO=$(net lo auto "" "")
DHCP_NC=$(net tst0 auto "" "")
W1='Wired connection 1|802-3-ethernet|lo|auto'
W1S='Wired connection 1|802-3-ethernet|lo|manual'
W1NC='Wired connection 1|802-3-ethernet|tst0|manual'
MOD_STATIC="connection modify --temporary Wired connection 1 ipv4.method manual ipv4.addresses 192.168.5.20/24 ipv4.gateway  ipv4.dns "
MOD_DHCP="connection modify --temporary Wired connection 1 ipv4.method auto ipv4.addresses  ipv4.gateway  ipv4.dns "
UP="-w 20 connection up Wired connection 1"

echo "=== static IP ==="
check "no network.json -> nothing, success" "$(run_case - "$W1" "Wired connection 1:lo")" "rc=0 calls="
check "on a LAN (DHCP profile active) -> set + activated" \
  "$(run_case "$STATIC_LO" "$W1\n$AOI" "Wired connection 1:lo\nvision-eth1:eth1")" "rc=0 calls=$MOD_STATIC;$UP;"
has "  ... and reported" "$(result)" "ok lo: static 192.168.5.20/24 applied"
check "direct laptop link -> the DHCP server profile is left alone, the client profile takes over" \
  "$(run_case "$STATIC_LO" "$DIRECT\n$W1" "citostore-direct:lo")" "rc=0 calls=$MOD_STATIC;$UP;"
check "  ... and it is the one now active" "$(cat "$TMP/active")" "Wired connection 1:lo"
check "DHCP probe active -> the probe is left alone too" \
  "$(run_case "$STATIC_LO" "$PROBE\n$W1" "citostore-probe:lo")" "rc=0 calls=$MOD_STATIC;$UP;"
check "no cable -> profile set for when one comes, nothing activated, no failure" \
  "$(run_case "$STATIC_NC" "${W1NC/manual/auto}" "")" \
  "rc=0 calls=connection modify --temporary Wired connection 1 ipv4.method manual ipv4.addresses 192.168.5.20/24 ipv4.gateway  ipv4.dns ;"
has "  ... and says so" "$(result)" "no cable"

start=$(date +%s)
got=$(run_case "$STATIC_LO" "$W1" "" 0 4)
took=$(( $(date +%s) - start ))
check "boot: the profile appears only on the 4th look -> waits, then applied" "$got" "rc=0 calls=$MOD_STATIC;$UP;"
check "  ... and it actually waited" "$(( took >= 2 && took <= 6 ))" "1"

start=$(date +%s)
got=$(run_case "$STATIC_LO" "$DIRECT\n$AOI" "" 0 1 2)
took=$(( $(date +%s) - start ))
check "no client profile at all -> gives up after the wait, reports failure, touches nothing" "$got" "rc=1 calls="
check "  ... not forever" "$(( took >= 2 && took <= 5 ))" "1"
has "  ... and reported" "$(result)" "FAIL lo: no NetworkManager profile"

check "static without an address -> refused" \
  "$(run_case "$(net lo manual "" 24)" "$W1" "Wired connection 1:lo")" "rc=1 calls="
got=$(MODIFY_ERR="Error: invalid IP address" run_case "$STATIC_LO" "$W1" "Wired connection 1:lo")
check "nmcli refuses the address -> failure" "$got" "rc=1 calls=$MOD_STATIC;"
has "  ... with NetworkManager's reason for the WebUI" "$(result)" "FAIL lo: static 192.168.5.20/24 refused: Error: invalid IP address"
check "activation fails -> failure" \
  "$(run_case "$STATIC_LO" "$W1" "Wired connection 1:lo" 4)" "rc=1 calls=$MOD_STATIC;$UP;"

echo "=== DHCP ==="
start=$(date +%s)
got=$(run_case "$DHCP_LO" "$W1" "" 0 1)
took=$(( $(date +%s) - start ))
check "already DHCP -> nothing to do" "$got" "rc=0 calls="
check "  ... without waiting" "$(( took <= 1 ))" "1"
check "direct laptop link in DHCP mode -> nothing touched, the DHCP server keeps serving" \
  "$(run_case "$DHCP_LO" "$DIRECT\n$W1" "citostore-direct:lo")" "rc=0 calls="
check "static -> DHCP on a LAN -> set + activated" \
  "$(run_case "$DHCP_LO" "$W1S" "Wired connection 1:lo")" "rc=0 calls=$MOD_DHCP;$UP;"
got=$(run_case "$DHCP_LO" "$W1S" "Wired connection 1:lo" 4)
has "static -> DHCP, no DHCP server answers -> handed to mdns-apply-mode" "$got" \
  "rc=0 calls=$MOD_DHCP;$UP;systemd-run --quiet --collect --no-block --unit=citostore-carrier-wait"
has "  ... which re-decides like a re-plug" "$got" "mdns-apply-mode.sh carrier-wait"
has "  ... and the WebUI hears why" "$(result)" "ok lo: DHCP — no DHCP server answered"
check "static -> DHCP without a cable -> set for the next cable only" \
  "$(run_case "$DHCP_NC" "$W1NC" "")" "rc=0 calls=${MOD_DHCP};"

echo "=== never saved to disk ==="
for f in "$STATIC_LO" "$DHCP_LO"; do
  run_case "$f" "$W1S" "Wired connection 1:lo" >/dev/null
  bad=$(grep "modify" "$TMP/calls" | grep -vc "^connection modify --temporary " || true)
  check "every modify is --temporary ($(grep -o '"method": "[a-z]*"' <<< "$f"))" "$bad" "0"
done

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"

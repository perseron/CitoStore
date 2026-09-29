#!/usr/bin/env bash
set -euo pipefail

# apply-network.sh runs at boot right after NetworkManager starts, ~3s before
# NM activates eth0 (carrier). It used to give up at once ("no active
# connection"), so a static IP set in the WebUI never survived a reboot. It must
# now wait for the connection and then apply the static config; with DHCP (the
# NM default) and nothing active it must not wait or fail.
#
# nmcli is stubbed: the active-connection query answers with eth0's connection
# only from the Nth poll on, and every modify/up is recorded. Needs root only
# because apply-network.sh insists on it, plus python3:
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

cat > "$TMP/bin/nmcli" <<EOF
#!/bin/bash
if [[ "\$*" == "-t -f NAME,DEVICE connection show --active" ]]; then
  n=\$(( \$(cat "$TMP/polls" 2>/dev/null || echo 0) + 1 ))
  echo "\$n" > "$TMP/polls"
  echo "lo:lo"
  after=\$(cat "$TMP/active_after")
  if ((after > 0 && n >= after)); then echo "Wired connection 1:eth0"; fi
  exit 0
fi
echo "\$*" >> "$TMP/calls"
EOF
chmod +x "$TMP/bin/nmcli"

# One case = fresh state; prints "rc=<n> calls=<...>".
run_case() {  # <network.json content or "-" for none> <poll that sees eth0 active, 0 = never> [wait sec]
  rm -f "$TMP/calls" "$TMP/polls" "$TMP/state.json"
  [[ "$1" == "-" ]] || printf '%s' "$1" > "$TMP/state.json"
  echo "$2" > "$TMP/active_after"
  local rc=0
  PATH="$TMP/bin:$PATH" NETWORK_STATE_FILE="$TMP/state.json" APPLY_NETWORK_WAIT_SEC="${3:-5}" \
    bash "$GW/scripts/apply-network.sh" >/dev/null 2>&1 || rc=$?
  echo "rc=$rc calls=$(cat "$TMP/calls" 2>/dev/null | tr '\n' ';' || true)"
}

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

STATIC='{"interface": "eth0", "method": "manual", "address": "10.10.10.50", "prefix": "24", "gateway": "", "dns": ""}'
DHCP='{"interface": "eth0", "method": "auto", "address": "", "prefix": "", "gateway": "", "dns": ""}'
APPLIED="rc=0 calls=connection modify --temporary Wired connection 1 ipv4.method manual ipv4.addresses 10.10.10.50/24 ipv4.gateway  ipv4.dns ;connection up Wired connection 1;"

echo "=== static IP ==="
check "no network.json -> nothing, success" "$(run_case - 1)" "rc=0 calls="
check "eth0 already active -> static applied" "$(run_case "$STATIC" 1)" "$APPLIED"

start=$(date +%s)
got=$(run_case "$STATIC" 4)
took=$(( $(date +%s) - start ))
check "eth0 active only on the 4th poll (the boot race) -> waits, then applied" "$got" "$APPLIED"
check "  ... and it actually waited (~3s)" "$(( took >= 2 && took <= 6 ))" "1"

start=$(date +%s)
got=$(run_case "$STATIC" 0 2)
took=$(( $(date +%s) - start ))
check "never active (no cable) -> gives up, reports failure, touches nothing" "$got" "rc=1 calls="
check "  ... after the configured wait, not forever" "$(( took >= 2 && took <= 5 ))" "1"

check "static without an address -> refused" \
  "$(run_case '{"interface": "eth0", "method": "manual", "address": "", "prefix": "24"}' 1)" "rc=1 calls="

echo "=== DHCP ==="
start=$(date +%s)
got=$(run_case "$DHCP" 0 5)
took=$(( $(date +%s) - start ))
check "DHCP with nothing active -> success, nothing to do" "$got" "rc=0 calls="
check "  ... without waiting" "$(( took <= 1 ))" "1"
check "DHCP with eth0 active -> set to auto" "$(run_case "$DHCP" 1)" \
  "rc=0 calls=connection modify --temporary Wired connection 1 ipv4.method auto ipv4.addresses  ipv4.gateway  ipv4.dns ;connection up Wired connection 1;"

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"

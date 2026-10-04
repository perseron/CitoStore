#!/usr/bin/env bash
# shellcheck disable=SC2034  # the ETH1_*/MDNS_* settings are read by the sourced aoi_link_issues
set -euo pipefail

# aoi_link_issues (common.sh) puts two AOI-link problems into the health that
# nothing else shows: a cable in eth1 but its address refused (duplicate
# address detection — a LAN cable in the AOI port), only once that has lasted
# 20 s; and eth0 on a network overlapping eth1's. `ip` is stubbed; the eth1
# interface is "lo" when a cable is wanted (carrier reads 1) and "tst0" when
# not (no such interface):
#   docker run --rm -v "$PWD:/gw:ro" debian:bookworm bash /gw/tests/functional/test_aoi_link_health.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# ip -4 -o addr show dev <if>: one line per address listed in $TMP/addr_<if>
cat > "$TMP/bin/ip" <<EOF
#!/bin/bash
f="$TMP/addr_\${@: -1}"
[[ -f "\$f" ]] || exit 1
while read -r a; do [[ -n "\$a" ]] && echo "2: \${@: -1}    inet \$a brd x scope global \${@: -1}"; done < "\$f"
exit 0
EOF
chmod +x "$TMP/bin/ip"
export PATH="$TMP/bin:$PATH"
export AOI_NOADDR_FILE=$TMP/noaddr

# shellcheck source=/dev/null
source <(tr -d '\r' < "$GW/scripts/common.sh")

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

ETH1_ENABLED=true ETH1_ADDRESS=192.168.100.1 ETH1_PREFIX=24 MDNS_INTERFACE=eth0
echo "10.10.10.1/24" > "$TMP/addr_eth0"

echo "=== eth1 address ==="
ETH1_INTERFACE=lo; echo "192.168.100.1/24" > "$TMP/addr_lo"
check "cable in, address set -> nothing" "$(aoi_link_issues)" ""
: > "$TMP/addr_lo"
check "cable in, no address, just now -> not yet (activation may be running)" "$(aoi_link_issues)" ""
echo $(( $(date +%s) - 25 )) > "$AOI_NOADDR_FILE"
check "  ... still none 25 s later -> reported" "$(aoi_link_issues)" \
  "AOI link (lo): cable in, but 192.168.100.1 could not be set - already used by another host on that cable?"
echo "192.168.100.1/24" > "$TMP/addr_lo"
aoi_link_issues >/dev/null
check "address back -> the clock resets" "$(test -e "$AOI_NOADDR_FILE" && echo kept || echo reset)" "reset"
ETH1_INTERFACE=tst0
check "no cable -> nothing (no address expected)" "$(aoi_link_issues)" ""
ETH1_INTERFACE=lo; : > "$TMP/addr_lo"; echo 0 > "$AOI_NOADDR_FILE"
check "eth1 off -> nothing" "$(ETH1_ENABLED=false aoi_link_issues)" ""
echo "garbage" > "$AOI_NOADDR_FILE"
check "a damaged timestamp starts over, does not abort" "$(aoi_link_issues; echo rc=$?)" "rc=0"

echo "=== eth0 overlapping eth1 ==="
ETH1_INTERFACE=tst0
echo "192.168.100.37/24" > "$TMP/addr_eth0"
check "eth0 got an address in the AOI subnet -> reported" "$(aoi_link_issues)" \
  "eth0 is on 192.168.100.37/24, overlapping the AOI link (192.168.100.1/24): give eth1 another subnet"
echo "192.168.0.10/16" > "$TMP/addr_eth0"
check "eth0's wider network contains the AOI subnet -> reported" "$(aoi_link_issues | grep -c overlapping)" 1
echo "192.168.101.5/24" > "$TMP/addr_eth0"
check "neighbouring subnet -> nothing" "$(aoi_link_issues)" ""
printf '10.10.10.1/24\n192.168.100.9/24\n' > "$TMP/addr_eth0"
check "second eth0 address overlapping -> reported once" "$(aoi_link_issues | grep -c overlapping)" 1
rm -f "$TMP/addr_eth0"
check "no eth0 (unplugged) -> nothing" "$(aoi_link_issues)" ""

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"

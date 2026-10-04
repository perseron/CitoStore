#!/usr/bin/env bash
set -euo pipefail

# Unit/drop-in patterns that turned into restart loops on a unit without an
# eth0 address (cable unplugged, or an AOI on eth1 only). Run in a container
# with systemd for systemd-analyze:
#   docker run --rm -v "$PWD:/src:ro" debian:bookworm bash -c \
#     'apt-get update -qq && apt-get install -y -qq systemd >/dev/null; \
#      cp -r /src /gw && bash /gw/tests/functional/test_service_units.sh'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }
D="$GW/systemd/nmbd.service.d/network.conf"

echo "=== nmbd waits for its interface itself (no start timeout + restart loop) ==="
check "Type=simple" "$(tr -d '\r' < "$D" | grep -c '^Type=simple$')" 1
check "no start timeout to trip while it waits" "$(tr -d '\r' < "$D" | grep -c '^TimeoutStartSec=')" 0
check "still restarted if it crashes" "$(tr -d '\r' < "$D" | grep -c '^Restart=on-failure$')" 1

if command -v systemd-analyze >/dev/null 2>&1; then
  mkdir -p /etc/systemd/system/nmbd.service.d
  printf '[Unit]\nDescription=nmbd stub\n[Service]\nType=notify\nExecStart=/bin/true\n' > /etc/systemd/system/nmbd.service
  tr -d '\r' < "$D" > /etc/systemd/system/nmbd.service.d/network.conf
  out=$(SYSTEMD_LOG_LEVEL=err systemd-analyze verify /etc/systemd/system/nmbd.service 2>&1 | grep -iE "unknown|invalid|bad" || true)
  check "systemd-analyze accepts the drop-in" "$out" ""
fi

echo "=== no NetworkManager auto DHCP profile on the AOI link (eth1) ==="
block=$(tr -d '\r' < "$GW/install/40_install_services.sh" | sed -n '/^cat > \/etc\/NetworkManager\/conf.d\/90-citostore.conf <<EOF$/,/^EOF$/p')
check "installer writes the NM conf" "$(grep -c 'no-auto-default=interface-name:' <<<"$block")" 1
export ETH1_INTERFACE=eth1   # read by the eval below
conf=$(eval "${block/cat > \/etc\/NetworkManager\/conf.d\/90-citostore.conf/cat}")
check "  ... for eth1 only (eth0 keeps its auto profile)" "$(grep '^no-auto-default=' <<<"$conf")" "no-auto-default=interface-name:eth1"

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"

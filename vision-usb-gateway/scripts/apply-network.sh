#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

STATE_FILE=${NETWORK_STATE_FILE:-/srv/vision_mirror/.state/network.json}
# At boot this runs right after NetworkManager starts, but NM activates eth0
# only once the link has carrier — ~3s later on the 1G port (measured: script
# 5.3s, carrier + activation 8.0s). With no wait the static IP was never
# applied and the unit fell back to DHCP / direct mode on every reboot.
APPLY_NETWORK_WAIT_SEC=${APPLY_NETWORK_WAIT_SEC:-20}

if [[ ! -f "$STATE_FILE" ]]; then
  log "network state not found: $STATE_FILE"
  exit 0
fi

read_iface_method() {
  python3 - "$STATE_FILE" <<'PY'
import json, sys
from pathlib import Path
state = Path(sys.argv[1])
data = json.loads(state.read_text(encoding="utf-8"))
def g(key, default=""):
    v = data.get(key, default)
    return "" if v is None else str(v)
print(g("interface","eth0"))
print(g("method","auto"))
print(g("address",""))
print(g("prefix",""))
print(g("gateway",""))
print(g("dns",""))
PY
}

mapfile -t vals < <(read_iface_method)
iface="${vals[0]:-eth0}"
method="${vals[1]:-auto}"
address="${vals[2]:-}"
prefix="${vals[3]:-}"
gateway="${vals[4]:-}"
dns="${vals[5]:-}"

# --temporary: network.json is the persistent truth and this re-applies it every
# boot. A saved modify wrote the profile to /etc, which on the overlay-off first
# boot after a flash is the eMMC itself — the static IP then outlived
# network.json and came back on every boot (seen live on AOI1).
active_conn() {
  nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null     | awk -F: -v d="$iface" '$2==d{print $1; exit}'
}

conn=$(active_conn)
if [[ -z "$conn" && "$method" == "auto" ]]; then
  # DHCP is what NetworkManager does by default; nothing to change.
  log "no active connection for $iface yet; DHCP is the default, nothing to apply"
  exit 0
fi
waited=0
while [[ -z "$conn" ]] && ((waited < APPLY_NETWORK_WAIT_SEC)); do
  sleep 1
  waited=$((waited + 1))
  conn=$(active_conn)
done
if [[ -z "$conn" ]]; then
  log "no active connection for $iface after ${APPLY_NETWORK_WAIT_SEC}s (no cable?); static IP ${address}/${prefix} NOT applied this boot"
  exit 1
fi
((waited == 0)) || log "$iface connection '$conn' active after ${waited}s"

if [[ "$method" == "auto" ]]; then
  nmcli connection modify --temporary "$conn" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
else
  if [[ -z "$address" || -z "$prefix" ]]; then
    log "static config missing address/prefix"
    exit 1
  fi
  nmcli connection modify --temporary "$conn" ipv4.method manual ipv4.addresses "${address}/${prefix}" \
    ipv4.gateway "$gateway" ipv4.dns "$dns"
fi

nmcli connection up "$conn"
log "network config applied for $iface"

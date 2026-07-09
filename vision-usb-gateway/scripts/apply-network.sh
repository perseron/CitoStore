#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

STATE_FILE=/srv/vision_mirror/.state/network.json

if [[ ! -f "$STATE_FILE" ]]; then
  log "network state not found: $STATE_FILE"
  exit 0
fi

read_iface_method() {
  python3 - <<'PY'
import json
from pathlib import Path
state = Path("/srv/vision_mirror/.state/network.json")
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

conn=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$iface" '$2==d{print $1; exit}')
if [[ -z "$conn" ]]; then
  log "no active connection for interface: $iface"
  exit 1
fi

if [[ "$method" == "auto" ]]; then
  nmcli connection modify "$conn" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
else
  if [[ -z "$address" || -z "$prefix" ]]; then
    log "static config missing address/prefix"
    exit 1
  fi
  nmcli connection modify "$conn" ipv4.method manual ipv4.addresses "${address}/${prefix}" \
    ipv4.gateway "$gateway" ipv4.dns "$dns"
fi

nmcli connection up "$conn"
log "network config applied for $iface"

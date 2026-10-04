#!/usr/bin/env bash
set -euo pipefail

# Apply the base network setting (network.json: DHCP or a static IPv4 for the
# management interface, eth0) to NetworkManager. Runs at boot
# (vision-gw-network), when a cable is plugged into a static-IP unit
# (mdns-apply-mode carrier-wait) and two seconds after the WebUI saved a change
# (it answers first: the change can take away the address the browser uses).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config "${CONF_FILE:-}"
: "${MDNS_DIRECT_SUBNET:=10.10.10}"

STATE_FILE=${NETWORK_STATE_FILE:-/srv/vision_mirror/.state/network.json}
# The outcome of the last run, for the WebUI: it applies two seconds after
# answering, so it never sees nmcli's answer itself.
RESULT_FILE=${NETWORK_RESULT_FILE:-/run/vision-network-apply.json}
# At boot this runs right after NetworkManager starts, possibly before it has
# created the interface's profile.
APPLY_NETWORK_WAIT_SEC=${APPLY_NETWORK_WAIT_SEC:-20}
# Profiles mdns-apply-mode keeps on the interface for itself. Never the place
# for the operator's setting: citostore-direct IS the direct-link DHCP server —
# the WebUI used to rewrite it (it was the active profile on a laptop link),
# and a laptop plugged in later got no address until a reboot.
OWN_PROFILES=" citostore-direct citostore-probe "

result() {  # <ok: 1|0> <message>
  log "$2"
  python3 - "$1" "$2" "$RESULT_FILE" <<'PY' 2>/dev/null || true
import json, sys, time
with open(sys.argv[3], "w", encoding="utf-8") as fh:
    json.dump({"ok": sys.argv[1] == "1", "message": sys.argv[2], "ts": int(time.time())}, fh)
PY
}

if [[ ! -f "$STATE_FILE" ]]; then
  log "network state not found: $STATE_FILE (DHCP, NetworkManager's default)"
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

# The interface's own client profile: the active one unless that is one of
# ours (direct mode, DHCP probe), else NetworkManager's default profile for the
# interface ("Wired connection 1"), active or not.
lan_conn() {
  local name dev type
  while IFS=: read -r name dev; do
    if [[ "$dev" == "$iface" && "$OWN_PROFILES" != *" $name "* ]]; then
      echo "$name"
      return 0
    fi
  done < <(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null)
  while IFS=: read -r name type; do
    [[ "$type" == 802-3-ethernet && "$OWN_PROFILES" != *" $name "* ]] || continue
    if [[ "$(nmcli -g connection.interface-name connection show "$name" 2>/dev/null)" == "$iface" ]]; then
      echo "$name"
      return 0
    fi
  done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
  return 0
}

is_active() { nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -qxF "$1:$iface"; }
has_carrier() { [[ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" == 1 ]]; }

conn=$(lan_conn)
waited=0
while [[ -z "$conn" ]] && ((waited < APPLY_NETWORK_WAIT_SEC)); do
  sleep 1
  waited=$((waited + 1))
  conn=$(lan_conn)
done
if [[ -z "$conn" ]]; then
  result 0 "$iface: no NetworkManager profile after ${APPLY_NETWORK_WAIT_SEC}s; network setting NOT applied"
  exit 1
fi

# --temporary throughout: network.json is the persistent truth and this
# re-applies it every boot. A saved modify wrote the profile to /etc, which on
# the overlay-off first boot after a flash is the eMMC itself — the static IP
# then outlived network.json and came back on every boot (seen live on AOI1).
err=""
if [[ "$method" == "auto" ]]; then
  # DHCP is NetworkManager's default: at boot, on a direct laptop link (the
  # shared profile is serving) and on a LAN lease alike there is nothing to do.
  if [[ "$(nmcli -g ipv4.method connection show "$conn" 2>/dev/null)" == "auto" ]]; then
    result 1 "$iface: DHCP"
    exit 0
  fi
  if ! err=$(nmcli connection modify --temporary "$conn" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns "" 2>&1); then
    result 0 "$iface: switching to DHCP refused: $err"
    exit 1
  fi
  if ! is_active "$conn"; then
    result 1 "$iface: DHCP (from the next time the cable is plugged in)"
    exit 0
  fi
  # Bounded (a direct laptop link has no DHCP server to answer).
  if err=$(nmcli -w 20 connection up "$conn" 2>&1); then
    result 1 "$iface: DHCP applied"
    exit 0
  fi
  # No DHCP server: decide again like a re-plug — a late lease means network,
  # none means a laptop link, served from ${MDNS_DIRECT_SUBNET}.1. Nothing else
  # would: the unit sat without an address until the next reboot.
  "$SCRIPT_DIR/mdns-apply-mode.sh" redecide || true
  result 1 "$iface: DHCP — no DHCP server answered; on a direct laptop link the unit serves ${MDNS_DIRECT_SUBNET}.x itself in about a minute"
  exit 0
fi

if [[ -z "$address" || -z "$prefix" ]]; then
  result 0 "$iface: static config missing address/prefix"
  exit 1
fi
if ! err=$(nmcli connection modify --temporary "$conn" ipv4.method manual ipv4.addresses "${address}/${prefix}" \
    ipv4.gateway "$gateway" ipv4.dns "$dns" 2>&1); then
  result 0 "$iface: static ${address}/${prefix} refused: $err"
  exit 1
fi
if ! is_active "$conn" && ! has_carrier; then
  # No cable (e.g. at boot): NetworkManager brings the profile up with this
  # address when one is plugged in, and the carrier wait re-applies it then.
  result 1 "$iface: no cable — static ${address}/${prefix} is applied when one is plugged in"
  exit 0
fi
# Also takes the interface over from the direct-link DHCP server.
if ! err=$(nmcli -w 20 connection up "$conn" 2>&1); then
  result 0 "$iface: static ${address}/${prefix} could not be activated: $err"
  exit 1
fi
result 1 "$iface: static ${address}/${prefix} applied"

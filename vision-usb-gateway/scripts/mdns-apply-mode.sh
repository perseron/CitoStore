#!/usr/bin/env bash
set -euo pipefail

# Pick the mDNS name to advertise based on how MDNS_INTERFACE is connected:
#   - a routable (non-link-local) IPv4 present  -> "network mode": advertise the
#     configured NETBIOS_NAME (e.g. AOI1 -> AOI1.local)
#   - only a link-local 169.254 address / none  -> "direct 1-1 mode": advertise
#     the fixed MDNS_DIRECT_NAME (e.g. citostore.local)
#
# Static-IP units count as "network" (they have a routable address), so they keep
# the configured name — the direct fallback only triggers on a genuine 1-1 link
# with no DHCP server. The default is always network mode: the direct name is used
# only when we affirmatively see no routable address, so a slow/renewing DHCP can
# never flip us into 1-1 mode. Invoked by the NM dispatcher (after DHCP settles)
# and by citostore-mdns.service on boot.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

load_config
: "${MDNS_ENABLED:=true}"
: "${MDNS_INTERFACE:=eth0}"
: "${MDNS_DIRECT_NAME:=citostore.local}"
: "${NETBIOS_NAME:=CITOSTORE}"
# On a direct 1-1 link (no router) the board hands out DHCP itself so a laptop on
# "automatic" gets a real routable IP — no APIPA/link-local needed. MDNS_DIRECT_SUBNET
# is the /24 the board serves; the board takes .1.
: "${MDNS_DIRECT_DHCP:=true}"
: "${MDNS_DIRECT_SUBNET:=10.10.10}"
SHARED_CON=citostore-direct

action="${1:-}"

[[ "$MDNS_ENABLED" == "true" ]] || exit 0
command -v avahi-set-host-name >/dev/null 2>&1 || { log "avahi-utils missing; skipping mDNS name"; exit 0; }

shared_active() { nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -q "^$SHARED_CON:"; }

# When the 1-1 cable is physically UNPLUGGED while we are serving DHCP, stop
# serving and hand the interface back to the DHCP client — so a unit later moved
# onto a LAN never keeps serving rogue DHCP. Gate on real carrier loss (no
# LOWER_UP): a "down" event also fires when the boot decision switches the
# interface from the DHCP client to the shared connection (the old connection
# deactivates) — that is NOT an unplug (the cable is still up), and acting on it
# would tear down the DHCP server we just started (flap). The direct<->network
# switch is otherwise decided at the next boot.
if [[ "$MDNS_DIRECT_DHCP" == "true" && "$action" == "down" ]] && shared_active \
   && ! ip link show "$MDNS_INTERFACE" 2>/dev/null | grep -q 'LOWER_UP'; then
  log "mDNS: $MDNS_INTERFACE cable unplugged while serving DHCP -> releasing to DHCP client"
  nmcli connection down "$SHARED_CON" >/dev/null 2>&1 || true
  nmcli device connect "$MDNS_INTERFACE" >/dev/null 2>&1 || true
  exit 0
fi

# A "routable" address that is neither link-local nor our own shared subnet means
# we are on a real network (router DHCP or a static IP).
routable=$(ip -4 -o addr show dev "$MDNS_INTERFACE" 2>/dev/null \
  | awk '{print $4}' | cut -d/ -f1 \
  | grep -vE "^169\.254\.|^${MDNS_DIRECT_SUBNET//./\\.}\." | head -1 || true)

# The advertised name is always the configured NETBIOS_NAME (e.g. AOI1 ->
# AOI1.local), on a network and on a direct link alike, so operators reach the
# unit by the name they gave it.
target="$NETBIOS_NAME"
if [[ -n "$routable" ]]; then
  mode="network"
  # Leave a 1-1 link: hand control of the interface back to the DHCP client.
  if [[ "$MDNS_DIRECT_DHCP" == "true" ]] && shared_active; then
    log "mDNS: network detected -> stopping direct-link DHCP server"
    nmcli connection down "$SHARED_CON" >/dev/null 2>&1 || true
    nmcli device connect "$MDNS_INTERFACE" >/dev/null 2>&1 || true
  fi
else
  mode="direct"
  # No routable address = a 1-1 link with no router, so become the DHCP server and
  # hand the laptop a real IP. Decided at boot only (action=boot), after
  # network-online has let DHCP settle — no runtime hot-switch, and never during a
  # LAN's brief DHCP-acquisition window. A static-IP unit always has a routable
  # address, so it takes the network branch above and never serves DHCP.
  if [[ "$action" == "boot" && "$MDNS_DIRECT_DHCP" == "true" ]] \
     && command -v nmcli >/dev/null 2>&1 && ! shared_active; then
    # Only if this interface is actually a DHCP client (not a deliberate static IP).
    con=$(nmcli -g GENERAL.CONNECTION device show "$MDNS_INTERFACE" 2>/dev/null || true)
    method=$(nmcli -g ipv4.method connection show "$con" 2>/dev/null || echo auto)
    if [[ "$method" == "auto" ]]; then
      log "mDNS: direct 1-1 link at boot -> serving DHCP on $MDNS_INTERFACE (${MDNS_DIRECT_SUBNET}.1)"
      nmcli connection up "$SHARED_CON" >/dev/null 2>&1 || true
    else
      log "mDNS: $MDNS_INTERFACE is $method (fixed IP) -> not serving DHCP"
    fi
  fi
fi

# The advertised name (NETBIOS_NAME) is set authoritatively by 75_configure_mdns
# via avahi's host-name; nothing to switch at runtime. Record the current mode.
prev=$(cat /run/citostore-mdns.mode 2>/dev/null || true)
if [[ "$prev" != "$mode" ]]; then
  printf '%s' "$mode" > /run/citostore-mdns.mode 2>/dev/null || true
  log "mDNS: $mode mode on $MDNS_INTERFACE -> advertising ${target}.local"
fi

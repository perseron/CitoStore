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
# with no DHCP server. Invoked by the NM dispatcher (after DHCP settles) and by
# citostore-mdns.service on boot, where it waits for DHCP before ruling out a
# network (see MDNS_NETWORK_WAIT_SEC below).

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
# How long the boot decision waits for DHCP before concluding there is no network.
# Only spent on a link that never answers: a lease ends the wait immediately, so a
# normal LAN costs nothing. Must outlast a switch port that negotiates and runs
# spanning-tree before it will pass DHCP.
: "${MDNS_NETWORK_WAIT_SEC:=45}"
SHARED_CON=citostore-direct
PROBE_CON=citostore-probe

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
  # Delete the (runtime-only) profile before reconnecting: `nmcli device
  # connect` activates the best AVAILABLE profile, and with the shared profile
  # still present that is the shared profile itself — flapping the DHCP server
  # right back on. apply-shadow recreates the profile on the next boot; within
  # this boot a re-plugged 1-1 link needs a reboot anyway (decision is per-boot).
  nmcli connection delete "$SHARED_CON" >/dev/null 2>&1 || true
  nmcli device connect "$MDNS_INTERFACE" >/dev/null 2>&1 || true
  exit 0
fi

# A "routable" address that is neither link-local nor our own shared subnet means
# we are on a real network (router DHCP or a static IP).
routable_addr() {
  ip -4 -o addr show dev "$MDNS_INTERFACE" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 \
    | grep -vE "^169\.254\.|^${MDNS_DIRECT_SUBNET//./\\.}\." | head -1 || true
}

routable=$(routable_addr)

# Start an explicit runtime DHCP client on the interface. `nmcli device connect`
# must never be used for this: it activates the best AVAILABLE profile, which
# can be the shared (DHCP-server) profile itself when that is the only one
# matching the interface. The probe profile is runtime-only (save no).
start_dhcp_probe() {
  command -v nmcli >/dev/null 2>&1 || return 0
  local con
  con=$(nmcli -g GENERAL.CONNECTION device show "$MDNS_INTERFACE" 2>/dev/null || true)
  # Something real (a DHCP client or a deliberate static profile) already owns
  # the interface — leave it alone, the lease wait below will see its address.
  [[ -n "$con" && "$con" != "$SHARED_CON" ]] && return 0
  [[ "$con" == "$SHARED_CON" ]] && nmcli connection down "$SHARED_CON" >/dev/null 2>&1 || true
  nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$PROBE_CON" \
    || nmcli connection add save no type ethernet ifname "$MDNS_INTERFACE" con-name "$PROBE_CON" \
         connection.autoconnect no ipv4.method auto ipv6.method ignore >/dev/null 2>&1 || true
  nmcli -w 5 connection up "$PROBE_CON" >/dev/null 2>&1 || true
}

# At boot, "no address yet" is not "no network". network-online.target only means
# NetworkManager stopped waiting, and we cap that at 15s (see the wait-online
# drop-in) so a carrier-less eth1 cannot stall boot — a switch port that
# negotiates and runs spanning-tree pushes DHCP well past it. This decision is
# final for the boot, so getting it wrong puts a rogue DHCP server on a real LAN
# and takes the unit off its own subnet. Wait for the lease before ruling the
# network out; it arrives on a normal LAN in a second or two and ends the wait.
if [[ -z "$routable" && ( "$action" == "boot" || "$action" == "carrier-wait" ) ]]; then
  if [[ "$action" == "boot" ]] && ! ip link show "$MDNS_INTERFACE" 2>/dev/null | grep -q 'LOWER_UP'; then
    # No cable at boot. Serving DHCP NOW would poison a LAN the cable is later
    # plugged into (the decision used to be final for the boot). Advertise the
    # name, hand the serve decision to a background carrier wait so boot can
    # finish, and probe for a router only once a cable actually appears.
    log "mDNS: no carrier on $MDNS_INTERFACE at boot -> deferring DHCP-serve decision until a cable appears"
    printf 'direct' > /run/citostore-mdns.mode 2>/dev/null || true
    nohup "$SCRIPT_DIR/mdns-apply-mode.sh" carrier-wait >/dev/null 2>&1 &
    exit 0
  fi
  if [[ "$action" == "carrier-wait" ]]; then
    while ! ip link show "$MDNS_INTERFACE" 2>/dev/null | grep -q 'LOWER_UP'; do sleep 3; done
    log "mDNS: carrier appeared on $MDNS_INTERFACE -> probing for a DHCP server"
  fi
  # Waiting only helps if something is actually asking for a lease (a leftover
  # profile can suppress NM's auto-default DHCP connection entirely).
  start_dhcp_probe
  waited=0
  while ((waited < MDNS_NETWORK_WAIT_SEC)); do
    sleep 1
    waited=$((waited + 1))
    routable=$(routable_addr)
    [[ -n "$routable" ]] && break
  done
  if [[ -n "$routable" ]]; then
    log "mDNS: $MDNS_INTERFACE got a routable address after ${waited}s -> network"
  else
    log "mDNS: no routable address on $MDNS_INTERFACE after ${MDNS_NETWORK_WAIT_SEC}s -> direct 1-1 link"
  fi
fi

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
  # No routable address after the wait above = a 1-1 link with no router, so
  # become the DHCP server and hand the laptop a real IP. Decided at boot only
  # (action=boot) — no runtime hot-switch. A static-IP unit always has a routable
  # address, so it takes the network branch above and never serves DHCP; that is
  # the reason to give a unit that lives on a LAN a fixed address.
  if [[ ( "$action" == "boot" || "$action" == "carrier-wait" ) && "$MDNS_DIRECT_DHCP" == "true" ]] \
     && command -v nmcli >/dev/null 2>&1 && ! shared_active; then
    # Only if this interface is actually a DHCP client (not a deliberate static IP).
    con=$(nmcli -g GENERAL.CONNECTION device show "$MDNS_INTERFACE" 2>/dev/null || true)
    method=$(nmcli -g ipv4.method connection show "$con" 2>/dev/null || echo auto)
    if [[ "$method" == "auto" ]]; then
      log "mDNS: direct 1-1 link (${action}) -> serving DHCP on $MDNS_INTERFACE (${MDNS_DIRECT_SUBNET}.1)"
      # The probe lost (no DHCP server answered); clear it so it cannot fight
      # the shared connection for the interface.
      nmcli connection down "$PROBE_CON" >/dev/null 2>&1 || true
      nmcli connection delete "$PROBE_CON" >/dev/null 2>&1 || true
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

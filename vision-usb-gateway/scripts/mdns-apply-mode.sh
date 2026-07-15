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

[[ "$MDNS_ENABLED" == "true" ]] || exit 0
command -v avahi-set-host-name >/dev/null 2>&1 || { log "avahi-utils missing; skipping mDNS name"; exit 0; }

# Any IPv4 on the interface that is NOT link-local (169.254/16) means we are on a
# real network (DHCP or static).
routable=$(ip -4 -o addr show dev "$MDNS_INTERFACE" 2>/dev/null \
  | awk '{print $4}' | cut -d/ -f1 | grep -v '^169\.254\.' | head -1 || true)
if [[ -n "$routable" ]]; then
  target="$NETBIOS_NAME"
  mode="network"
else
  target="${MDNS_DIRECT_NAME%.local}"
  mode="direct"
fi

# Only act on a change (state file avoids restarting avahi's name needlessly).
state=/run/citostore-mdns.name
prev=$(cat "$state" 2>/dev/null || true)
if [[ "$prev" != "$target" ]]; then
  if avahi-set-host-name "$target" >/dev/null 2>&1; then
    printf '%s' "$target" > "$state" 2>/dev/null || true
    log "mDNS: $mode mode on $MDNS_INTERFACE -> advertising ${target}.local"
  else
    log "mDNS: failed to set host-name to $target"
  fi
fi

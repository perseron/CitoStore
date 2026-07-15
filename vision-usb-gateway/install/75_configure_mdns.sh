#!/usr/bin/env bash
set -euo pipefail

# Configure mDNS/zeroconf (.local) name resolution. Idempotent and overlay-safe:
# called by apply-shadow-config on every boot, driven by /etc/vision-gw.conf.
#
# On a normal network the advertised name is NETBIOS_NAME (AOI1 -> AOI1.local);
# on a direct 1-1 link with no router it falls back to MDNS_DIRECT_NAME
# (citostore.local). avahi is restricted to MDNS_INTERFACE so the isolated eth1
# (Ethernet-AOI) address is never advertised. The interface is given an IPv4
# link-local fallback so a direct laptop (also link-local) can resolve the name.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root
load_config

: "${MDNS_ENABLED:=true}"
: "${MDNS_INTERFACE:=eth0}"
: "${MDNS_DIRECT_NAME:=citostore.local}"
: "${NETBIOS_NAME:=CITOSTORE}"
: "${MDNS_DIRECT_DHCP:=true}"
: "${MDNS_DIRECT_SUBNET:=10.10.10}"

AVAHI_CONF=/etc/avahi/avahi-daemon.conf
DISPATCHER=/etc/NetworkManager/dispatcher.d/90-citostore-mdns
SHARED_CON=citostore-direct

if [[ "$MDNS_ENABLED" != "true" ]]; then
  log "mDNS disabled; stopping avahi"
  systemctl disable --now avahi-daemon.service avahi-daemon.socket >/dev/null 2>&1 || true
  rm -f "$DISPATCHER"
  exit 0
fi

if ! command -v avahi-daemon >/dev/null 2>&1; then
  log "avahi-daemon not installed; cannot enable mDNS (bake it into the image)"
  exit 0
fi

# ---- avahi-daemon.conf: default (network) name + interface restriction ----
set_conf() {  # key value
  local k="$1" v="$2"
  if grep -qE "^#?${k}=" "$AVAHI_CONF" 2>/dev/null; then
    sed -i "s|^#\?${k}=.*|${k}=${v}|" "$AVAHI_CONF"
  else
    # append under [server] if present, else at end
    if grep -q '^\[server\]' "$AVAHI_CONF" 2>/dev/null; then
      sed -i "0,/^\[server\]/s//[server]\n${k}=${v}/" "$AVAHI_CONF"
    else
      printf '\n[server]\n%s=%s\n' "$k" "$v" >> "$AVAHI_CONF"
    fi
  fi
}
[[ -f "$AVAHI_CONF" ]] || printf '[server]\n' > "$AVAHI_CONF"
set_conf host-name "$NETBIOS_NAME"
set_conf domain-name local
set_conf allow-interfaces "$MDNS_INTERFACE"
# Advertise IPv4 only. On a direct 1-1 link the interface has a routable IPv4
# from the board's own DHCP server (see below), so the name resolves to a plain
# IPv4 address — not an fe80:: link-local that browsers can't reliably reach.
set_conf use-ipv4 yes
set_conf use-ipv6 no
set_conf publish-workstation no

# ---- direct-link DHCP profile (NM "shared": static .1 + dnsmasq DHCP server) ----
# Activated by mdns-apply-mode only on a 1-1 link with no router; autoconnect=no
# so it never fights the DHCP client on a real network.
if [[ "$MDNS_DIRECT_DHCP" == "true" ]] && command -v nmcli >/dev/null 2>&1; then
  if ! nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$SHARED_CON"; then
    nmcli connection add type ethernet ifname "$MDNS_INTERFACE" con-name "$SHARED_CON" \
      connection.autoconnect no ipv4.method shared \
      ipv4.addresses "${MDNS_DIRECT_SUBNET}.1/24" ipv6.method ignore >/dev/null 2>&1 \
      || log "could not create $SHARED_CON shared profile"
  fi
fi

# ---- NetworkManager dispatcher: re-evaluate name when addressing changes ----
mkdir -p "$(dirname "$DISPATCHER")"
cat > "$DISPATCHER" <<DISPATCH
#!/bin/sh
# Managed by 75_configure_mdns.sh — re-evaluate mDNS name + direct-link DHCP when
# $MDNS_INTERFACE addressing changes. The action (up/down/...) is passed through
# so the helper can re-probe for a router when a 1-1 link is unplugged.
[ "\$1" = "$MDNS_INTERFACE" ] || exit 0
case "\$2" in
  up|down|dhcp4-change|dhcp6-change|connectivity-change)
    "$GATEWAY_HOME/scripts/mdns-apply-mode.sh" "\$2" >/dev/null 2>&1 || true ;;
esac
DISPATCH
chmod 0755 "$DISPATCHER"

systemctl enable --now avahi-daemon.service >/dev/null 2>&1 || true
systemctl restart avahi-daemon.service >/dev/null 2>&1 || true

# avahi now advertises the conf host-name (NETBIOS_NAME); seed the state so the
# mode helper only calls avahi-set-host-name when it actually needs to switch
# (i.e. into/out of the direct 1-1 name).
printf '%s' "$NETBIOS_NAME" > /run/citostore-mdns.name 2>/dev/null || true

# Set the correct name for the current mode right now.
"$GATEWAY_HOME/scripts/mdns-apply-mode.sh" || true
log "mDNS configured (iface=$MDNS_INTERFACE net-name=$NETBIOS_NAME direct=$MDNS_DIRECT_NAME)"

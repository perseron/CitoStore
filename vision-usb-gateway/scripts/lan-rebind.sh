#!/usr/bin/env bash
set -euo pipefail

# Re-bind the services that listen on a specific LAN address once that address
# exists. Called by the NetworkManager dispatcher (91-citostore-rebind, installed
# by 40_install_services.sh) as: lan-rebind.sh <iface> <action>.
#
# smbd runs with "bind interfaces only = yes", so it listens only on the
# addresses its interface has at the moment it starts — an address that appears
# later is never picked up. That is the normal case on a direct 1-1 laptop link:
# smbd starts at ~45s, but mdns-apply-mode.sh waits MDNS_NETWORK_WAIT_SEC for a
# DHCP lease before taking 10.10.10.1, so the share was reachable only on
# 127.0.0.1 (WebUI and SSH, bound to 0.0.0.0, worked — port 445 did not). A LAN
# whose DHCP is slower than the network-online cap, or a lease that changes the
# address, hits the same gap. vsftpd-mirror has it too: its listen_address is
# the interface IP captured when 80_configure_mirror_ftp.sh last ran.
#
# Restarts only when something is actually missing, so a DHCP renewal that keeps
# the same address never drops a connected client.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config "${CONF_FILE:-}"

iface="${1:-}"
action="${2:-}"

case "$action" in
  up|dhcp4-change|reapply) ;;
  *) exit 0 ;;
esac

: "${SMB_BIND_INTERFACE:=eth0}"
: "${MIRROR_FTP_ENABLED:=false}"
: "${MIRROR_FTP_BIND_INTERFACE:=eth0}"

[[ -n "$iface" ]] || exit 0

mapfile -t addrs < <(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
((${#addrs[@]})) || exit 0

# True if something listens on addr:port, directly or via a wildcard socket.
listening_on() {  # addr port
  ss -Hltn 2>/dev/null | awk '{print $4}' \
    | grep -qxE "(${1//./\\.}|0\.0\.0\.0|\*|\[::\]):$2"
}

if [[ "$iface" == "$SMB_BIND_INTERFACE" ]] && systemctl is-active --quiet smbd.service; then
  missing=()
  for a in "${addrs[@]}"; do
    listening_on "$a" 445 || missing+=("$a")
  done
  if ((${#missing[@]})); then
    log "lan-rebind: smbd not listening on ${missing[*]} ($iface $action) -> restarting nmbd + smbd"
    # --no-block: never hold up the NetworkManager dispatcher queue on a restart.
    systemctl --no-block restart nmbd.service smbd.service || log "lan-rebind: samba restart failed"
  fi
fi

if [[ "$MIRROR_FTP_ENABLED" == "true" && "$iface" == "$MIRROR_FTP_BIND_INTERFACE" ]]; then
  current=$(sed -n 's/^listen_address=//p' /etc/vsftpd-mirror.conf 2>/dev/null | head -1)
  if [[ "$current" != "${addrs[0]}" ]]; then
    log "lan-rebind: vsftpd-mirror bound to '${current:-none}', $iface is now ${addrs[0]} -> reconfiguring"
    "$GATEWAY_HOME/install/80_configure_mirror_ftp.sh" || log "lan-rebind: mirror FTP reconfigure failed"
  fi
fi

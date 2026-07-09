#!/usr/bin/env bash
set -euo pipefail

# Import a config bundle produced by export-config-bundle.sh onto a freshly
# provisioned device. Run this on the NEW device AFTER 40_install_services.sh
# and BEFORE enabling the read-only overlay.
#
# It seeds /srv/vision_mirror/.state, then leaves the hardware-sensitive keys
# for you to review before applying.
#
# Usage:
#   sudo scripts/import-config-bundle.sh /path/to/bundle.tgz [--apply]
#
# Without --apply it stages files and prints a review checklist.
# With --apply it also runs apply-shadow-config.sh.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

BUNDLE="${1:-}"
APPLY=false
[[ "${2:-}" == "--apply" ]] && APPLY=true
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "usage: $0 /path/to/bundle.tgz [--apply]" >&2
  exit 1
fi

STATE_DIR=/srv/vision_mirror/.state
safe_mkdir "$STATE_DIR"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$BUNDLE" -C "$STAGE"

if [[ -f "$STAGE/MANIFEST.txt" ]]; then
  log "importing bundle:"
  sed 's/^/  /' "$STAGE/MANIFEST.txt" >&2
fi

# Config becomes the WebUI shadow copy; apply-shadow-config promotes it to /etc.
if [[ -f "$STAGE/etc/vision-gw.conf" ]]; then
  cp "$STAGE/etc/vision-gw.conf" "$STATE_DIR/vision-gw.conf"
  cp "$STAGE/etc/vision-gw.conf" "$STATE_DIR/vision-gw.conf.last-good"
  log "staged vision-gw.conf -> shadow config"
fi

# Secrets + WebUI identity.
for f in webui.passwd webui.secret vision-nas.creds; do
  if [[ -f "$STAGE/state/$f" ]]; then
    cp "$STAGE/state/$f" "$STATE_DIR/$f"
    chmod 0600 "$STATE_DIR/$f"
    log "staged $f"
  fi
done

# AOI persist folder.
if [[ -d "$STAGE/state/aoi_settings" ]]; then
  rm -rf "$STATE_DIR/aoi_settings"
  cp -a "$STAGE/state/aoi_settings" "$STATE_DIR/aoi_settings"
  log "staged aoi_settings/"
fi

# Samba passdb (restore the existing SMB user/password).
if [[ -f "$STAGE/samba/passdb.tdb" && -d /var/lib/samba/private ]]; then
  cp "$STAGE/samba/passdb.tdb" /var/lib/samba/private/passdb.tdb
  log "restored Samba passdb.tdb (existing SMB password carried over)"
fi

# Network profiles are NOT auto-imported: interface names and the base board
# differ. They are left in the bundle for manual `nmcli connection import`.
if ls "$STAGE"/network/*.nmconnection >/dev/null 2>&1; then
  cp "$STAGE"/network/*.nmconnection "$STATE_DIR/" 2>/dev/null || true
  log "network profiles copied to $STATE_DIR (review, then nmcli connection import)"
fi

cat >&2 <<'REVIEW'

------------------------------------------------------------------
REVIEW BEFORE APPLYING (hardware changed: 4GB->2GB, WiFi->none,
IO Board -> ETH-RS485-4G-BASE, new empty NVMe):

  [ ] NVME_DEVICE            still /dev/nvme0n1 ? (lsblk)
  [ ] MIRROR_SIZE / THINPOOL_SIZE / USB_LV_SIZE  match the NEW NVMe capacity
  [ ] SMB_BIND_INTERFACE     still eth0 ? (ip -o link)
  [ ] WEBUI_BIND / WEBUI_PORT unchanged
  [ ] USB_VOLUME_SERIAL      KEEP identical so the AOI host keeps its drive letter
  [ ] USB_SERIAL / VID / PID  keep identical for the same USB identity
  [ ] no WiFi/hotspot keys point at a wlan interface

Edit the staged config if needed:
  sudo nano /srv/vision_mirror/.state/vision-gw.conf

Then apply:
  sudo scripts/apply-shadow-config.sh
------------------------------------------------------------------
REVIEW

if $APPLY; then
  log "applying shadow config"
  "$(dirname "${BASH_SOURCE[0]}")/apply-shadow-config.sh"
fi

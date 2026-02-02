#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root

BOOT_RO=false
for arg in "$@"; do
  case "$arg" in
    --boot-ro) BOOT_RO=true ;;
  esac
done

BOOT_MOUNT=/boot/firmware
BOOT_WAS_RO=false
if mountpoint -q "$BOOT_MOUNT"; then
  opts=$(findmnt -no OPTIONS "$BOOT_MOUNT" 2>/dev/null || true)
  if echo ",$opts," | grep -q ",ro,"; then
    BOOT_WAS_RO=true
    log "remounting $BOOT_MOUNT read-write"
    mount -o remount,rw "$BOOT_MOUNT"
  fi
fi

cmdline_add "overlayroot=tmpfs:recurse=0"

if command -v raspi-config >/dev/null 2>&1; then
  log "enabling overlayfs via raspi-config"
  raspi-config nonint do_overlayfs 0 || true
fi

# overlayroot config for Debian overlayroot if present
if [[ -f /etc/overlayroot.conf ]]; then
  sed -i 's/^overlayroot=.*/overlayroot=tmpfs:recurse=0/' /etc/overlayroot.conf
else
  echo 'overlayroot=tmpfs:recurse=0' > /etc/overlayroot.conf
fi

# journald volatile
JOURNALD=/etc/systemd/journald.conf
if [[ -f "$JOURNALD" ]]; then
  sed -i 's/^#*Storage=.*/Storage=volatile/' "$JOURNALD"
else
  echo 'Storage=volatile' > "$JOURNALD"
fi

if $BOOT_RO; then
  log "setting boot partition read-only in fstab"
  if ! grep -q '^/dev/mmcblk0p1' /etc/fstab; then
    echo '/dev/mmcblk0p1 /boot/firmware vfat ro,defaults 0 2' >> /etc/fstab
  else
    sed -i 's#/boot/firmware vfat #/boot/firmware vfat ro,#' /etc/fstab
  fi
fi

if $BOOT_RO || $BOOT_WAS_RO; then
  if mountpoint -q "$BOOT_MOUNT"; then
    log "remounting $BOOT_MOUNT read-only"
    mount -o remount,ro "$BOOT_MOUNT"
  fi
fi

log "overlay configuration applied"

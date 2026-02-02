#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root

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

BOOT_RW=false
for arg in "$@"; do
  case "$arg" in
    --boot-rw) BOOT_RW=true ;;
  esac
done

CMDLINE=/boot/firmware/cmdline.txt
if [[ -f "$CMDLINE" ]]; then
  cmdline=$(tr ' ' '\n' < "$CMDLINE" | grep -v '^overlayroot=tmpfs:recurse=0$' | paste -sd' ' -)
  if [[ -z "$cmdline" ]]; then
    log "cmdline would be empty; refusing to write"
    exit 1
  fi
  echo "$cmdline" > "$CMDLINE"
fi

if [[ -f /etc/overlayroot.conf ]]; then
  sed -i '/^overlayroot=tmpfs:recurse=0$/d' /etc/overlayroot.conf
  if ! grep -q '.' /etc/overlayroot.conf; then
    rm -f /etc/overlayroot.conf
  fi
fi

if $BOOT_RW; then
  log "setting boot partition read-write in fstab"
  if grep -q '^/dev/mmcblk0p1' /etc/fstab; then
    sed -i 's#/boot/firmware vfat ro,#/boot/firmware vfat #' /etc/fstab
  fi
fi

if $BOOT_WAS_RO && ! $BOOT_RW; then
  if mountpoint -q "$BOOT_MOUNT"; then
    log "remounting $BOOT_MOUNT read-only"
    mount -o remount,ro "$BOOT_MOUNT"
  fi
fi

log "overlay disabled (reboot required)"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root
require_cmd update-initramfs

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

normalize_cmdline_remove_overlayroot() {
  local cmdline_file normalized
  for cmdline_file in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [[ -f "$cmdline_file" ]] || continue
    normalized=$(tr ' ' '\n' < "$cmdline_file" | awk '$0!="overlayroot=tmpfs:recurse=0" && $0!="boot=overlay"' | paste -sd' ' - || true)
    normalized=$(echo "$normalized" | xargs)
    if [[ -z "$normalized" ]]; then
      log "cmdline would be empty after removing overlay args; refusing to write"
      exit 1
    fi
    echo "$normalized" > "$cmdline_file"
  done
}

normalize_cmdline_remove_overlayroot

if command -v raspi-config >/dev/null 2>&1; then
  log "disabling overlayfs via raspi-config"
  raspi-config nonint do_overlayfs 1
  if raspi-config nonint get_overlayfs >/dev/null 2>/dev/null; then
    overlay_state=$(raspi-config nonint get_overlayfs || true)
    case "$overlay_state" in
      1|disabled|false) ;;
      *)
        log "overlay disable verification failed (raspi-config state=$overlay_state)"
        exit 1
        ;;
    esac
  fi
fi

if [[ -f /etc/overlayroot.conf ]]; then
  sed -i 's/^overlayroot=.*/overlayroot=disabled/' /etc/overlayroot.conf
else
  echo "overlayroot=disabled" > /etc/overlayroot.conf
fi

log "updating initramfs"
update-initramfs -u

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
log "verify after reboot:"
log "  grep -o 'overlayroot=[^ ]*' /proc/cmdline || echo 'overlayroot arg missing'"
log "  findmnt -no FSTYPE /"
log "expected: root filesystem type is ext4"

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

normalize_overlayroot_cmdline() {
  local cmdline_file="/boot/firmware/cmdline.txt"
  [[ -f "$cmdline_file" ]] || return 0
  local normalized
  normalized=$(tr ' ' '\n' < "$cmdline_file" | grep -v '^overlayroot=tmpfs:recurse=0$' | paste -sd' ' -)
  normalized="${normalized} overlayroot=tmpfs:recurse=0"
  normalized=$(echo "$normalized" | xargs)
  if [[ -z "$normalized" ]]; then
    log "cmdline would be empty; refusing to write"
    exit 1
  fi
  echo "$normalized" > "$cmdline_file"
}

maybe_recover_previous_failed_enable() {
  local current_root cmdline_count
  current_root=$(findmnt -no FSTYPE / 2>/dev/null || true)
  cmdline_count=$(grep -o 'overlayroot=tmpfs:recurse=0' /proc/cmdline 2>/dev/null | wc -l | xargs || echo 0)
  if [[ "$current_root" != "overlay" && "$cmdline_count" -gt 0 ]]; then
    log "detected previous overlay enable attempt (kernel arg present, root=$current_root)"
    if command -v raspi-config >/dev/null 2>&1; then
      log "attempting overlayfs recovery toggle via raspi-config"
      raspi-config nonint do_overlayfs 1 || true
      raspi-config nonint do_overlayfs 0
    fi
  fi
}

maybe_recover_previous_failed_enable
normalize_overlayroot_cmdline

overlay_method="overlayroot"
if command -v raspi-config >/dev/null 2>&1; then
  log "enabling overlayfs via raspi-config"
  raspi-config nonint do_overlayfs 0
  overlay_method="raspi-config"
  if raspi-config nonint get_overlayfs >/dev/null 2>&1; then
    overlay_state=$(raspi-config nonint get_overlayfs || true)
    case "$overlay_state" in
      0|enabled|true) ;;
      *)
        log "overlay enable verification failed (raspi-config state=$overlay_state)"
        exit 1
        ;;
    esac
  fi
elif ! command -v overlayroot >/dev/null 2>&1; then
  log "no supported overlay enable method found (raspi-config/overlayroot missing)"
  exit 1
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

log "overlay configuration applied using $overlay_method"
log "reboot required; verify after reboot:"
log "  grep -o 'overlayroot=[^ ]*' /proc/cmdline"
log "  findmnt -no FSTYPE /"
log "expected: root filesystem type is overlay"

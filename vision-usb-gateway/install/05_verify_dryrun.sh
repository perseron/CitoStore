#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

CONFIG_PATH="/etc/vision-gw.conf"
if [[ "${1:-}" == "--config" && -n "${2:-}" ]]; then
  CONFIG_PATH="$2"
fi

if [[ -f "$CONFIG_PATH" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_PATH"
else
  log "config not found at $CONFIG_PATH (using defaults)"
fi

warns=0
fails=0

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; warns=$((warns+1)); }
fail() { echo "FAIL: $*"; fails=$((fails+1)); }

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then ok "command $1"; else warn "missing command $1"; fi
}

check_file_contains() {
  local file="$1" pattern="$2" desc="$3"
  if [[ -f "$file" ]] && grep -q "$pattern" "$file"; then ok "$desc"; else warn "$desc"; fi
}

check_exists() {
  local path="$1" desc="$2"
  if [[ -e "$path" ]]; then ok "$desc"; else warn "$desc"; fi
}

check_cmd lvm
check_cmd lvcreate
check_cmd lvs
check_cmd mkfs.vfat
check_cmd fsck.fat
check_cmd rsync
check_cmd smbd
check_cmd mount
check_cmd umount

check_file_contains /boot/firmware/config.txt '^dtoverlay=dwc2' "dwc2 overlay in config.txt"
check_file_contains /boot/firmware/cmdline.txt 'modules-load=dwc2' "dwc2 in cmdline"
check_file_contains /boot/firmware/cmdline.txt 'overlayroot=tmpfs:recurse=0' "overlayroot in cmdline"
check_file_contains /etc/modules '^dwc2' "dwc2 in /etc/modules"
check_file_contains /etc/modules '^libcomposite' "libcomposite in /etc/modules"

: "${NVME_DEVICE:=/dev/nvme0n1}"
: "${LVM_VG:=vg0}"
: "${MIRROR_LV:=mirror}"
: "${MIRROR_MOUNT:=/srv/vision_mirror}"
: "${THINPOOL_LV:=usbpool}"

check_exists "$NVME_DEVICE" "NVMe device $NVME_DEVICE"
check_exists "/dev/$LVM_VG/$MIRROR_LV" "mirror LV"
check_exists "/dev/$LVM_VG/$THINPOOL_LV" "thinpool LV"

if [[ ${#USB_LVS[@]} -eq 0 ]]; then
  warn "USB_LVS not set; default will be usb_0"
else
  for lv in "${USB_LVS[@]}"; do
    check_exists "/dev/$LVM_VG/$lv" "USB LV $lv"
  done
fi

if grep -q "^/dev/$LVM_VG/$MIRROR_LV" /etc/fstab 2>/dev/null; then
  ok "fstab mirror mount"
else
  warn "fstab mirror mount"
fi

check_exists "$MIRROR_MOUNT" "mirror mount dir"
check_exists "$MIRROR_MOUNT/.state" "mirror state dir"
check_exists /etc/vision-gw.env "systemd env file"

if [[ $fails -gt 0 ]]; then
  exit 1
fi

if [[ $warns -gt 0 ]]; then
  exit 2
fi

exit 0
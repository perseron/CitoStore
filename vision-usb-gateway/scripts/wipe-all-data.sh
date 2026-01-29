#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

VG="${LVM_VG:-vg0}"
MIRROR_LV="${MIRROR_LV:-mirror}"
MIRROR_MOUNT="${MIRROR_MOUNT:-/srv/vision_mirror}"
USB_LABEL="${USB_LABEL:-VISIONUSB}"
USB_LVS=("${USB_LVS[@]:-usb_0 usb_1 usb_2}")

CONFIRM=false
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage:
  wipe-all-data.sh --i-know-what-im-doing [--dry-run]

This wipes ALL data:
 - mirror LV (/dev/<vg>/<mirror>) is reformatted (ext4)
 - all USB LVs are reformatted (FAT32)
 - services are stopped and restarted
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --i-know-what-im-doing)
      CONFIRM=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$CONFIRM" != "true" ]]; then
  echo "Refusing to run without --i-know-what-im-doing" >&2
  exit 1
fi

echo "WIPING ALL DATA:"
echo "  VG: $VG"
echo "  Mirror LV: /dev/$VG/$MIRROR_LV -> $MIRROR_MOUNT"
echo "  USB LVs: ${USB_LVS[*]}"
echo "  USB label: $USB_LABEL"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY-RUN: no changes will be made"
  exit 0
fi

systemctl stop vision-sync.service vision-monitor.service vision-rotator.service || true
systemctl stop usb-gadget.service || true

umount "$MIRROR_MOUNT" || true
mkfs.ext4 -F "/dev/$VG/$MIRROR_LV"
mount "/dev/$VG/$MIRROR_LV" "$MIRROR_MOUNT"
rm -rf "$MIRROR_MOUNT/.state" || true

for lv in "${USB_LVS[@]}"; do
  mkfs.vfat -F 32 -n "$USB_LABEL" "/dev/$VG/$lv"
done

systemctl start usb-gadget.service || true
systemctl start vision-sync.service vision-monitor.service vision-rotator.service || true

echo "Done."

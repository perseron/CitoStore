#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root
load_config

WIPE=false
for arg in "$@"; do
  case "$arg" in
    --wipe|--i-know-what-im-doing) WIPE=true ;;
  esac
done

: "${NVME_DEVICE:=/dev/nvme0n1}"
: "${LVM_VG:=vg0}"
: "${MIRROR_LV:=mirror}"
: "${MIRROR_MOUNT:=/srv/vision_mirror}"
: "${MIRROR_SIZE:=1.2T}"
: "${THINPOOL_LV:=usbpool}"
: "${THINPOOL_SIZE:=900G}"
: "${THINPOOL_META_SIZE:=8G}"
: "${USB_LABEL:=VISIONUSB}"
: "${USB_LV_SIZE:=100G}"

if [[ ${#USB_LVS[@]} -eq 0 ]]; then
  USB_LVS=(usb_0)
fi

if [[ ! -b "$NVME_DEVICE" ]]; then
  echo "nvme device not found: $NVME_DEVICE" >&2
  exit 1
fi

PART=${NVME_DEVICE}p1

if $WIPE; then
  log "wipe enabled: partitioning $NVME_DEVICE"
  require_cmd parted
  parted -s "$NVME_DEVICE" mklabel gpt
  parted -s "$NVME_DEVICE" mkpart primary 1MiB 100%
  partprobe "$NVME_DEVICE"
  pvcreate -ff -y "$PART"
else
  if [[ ! -b "$PART" ]]; then
    echo "partition $PART missing; re-run with --wipe" >&2
    exit 1
  fi
fi

if ! vgdisplay "$LVM_VG" >/dev/null 2>&1; then
  log "creating volume group $LVM_VG"
  vgcreate "$LVM_VG" "$PART"
fi

if ! lvdisplay "$LVM_VG/$MIRROR_LV" >/dev/null 2>&1; then
  log "creating mirror LV $MIRROR_LV"
  lvcreate -L "$MIRROR_SIZE" -n "$MIRROR_LV" "$LVM_VG"
  mkfs.ext4 -F "/dev/$LVM_VG/$MIRROR_LV"
fi

if ! lvdisplay "$LVM_VG/$THINPOOL_LV" >/dev/null 2>&1; then
  log "creating thinpool $THINPOOL_LV"
  lvcreate --type thin-pool -L "$THINPOOL_SIZE" --poolmetadatasize "$THINPOOL_META_SIZE" -n "$THINPOOL_LV" "$LVM_VG"
fi

safe_mkdir "$MIRROR_MOUNT"
if ! grep -q "^/dev/$LVM_VG/$MIRROR_LV" /etc/fstab; then
  echo "/dev/$LVM_VG/$MIRROR_LV $MIRROR_MOUNT ext4 noatime,commit=30 0 2" >> /etc/fstab
fi

for lv in "${USB_LVS[@]}"; do
  if ! lvdisplay "$LVM_VG/$lv" >/dev/null 2>&1; then
    log "creating USB LV $lv"
    lvcreate -V "$USB_LV_SIZE" -T "$LVM_VG/$THINPOOL_LV" -n "$lv"
    mkfs.vfat -F 32 -n "$USB_LABEL" "/dev/$LVM_VG/$lv"
  fi
done

log "NVMe LVM setup complete"
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
: "${USB_PERSIST_DIR:=aoi_settings}"
: "${USB_PERSIST_BACKING:=$MIRROR_MOUNT/.state/$USB_PERSIST_DIR}"

CONFIRM=false
DRY_RUN=false
FORCE_UMOUNT=false
BACKUP_DIR=/run/vision-wipe-backup

usage() {
  cat <<'EOF'
Usage:
  wipe-all-data.sh --i-know-what-im-doing [--dry-run] [--force-umount]

This wipes ALL data:
 - mirror LV (/dev/<vg>/<mirror>) is reformatted (ext4)
 - all USB LVs are reformatted (FAT32)
 - services are stopped and restarted

Configuration files are NOT modified. Use restore-defaults.sh to reset configs.
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
    --force-umount)
      FORCE_UMOUNT=true
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
if [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]; then
  echo "  USB persist dir: $USB_PERSIST_DIR"
  echo "  USB persist backing: $USB_PERSIST_BACKING"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY-RUN: no changes will be made"
  exit 0
fi

systemctl stop vision-sync.timer vision-monitor.timer vision-rotator.timer mirror-retention.timer nas-sync.timer || true
systemctl stop vision-sync.service vision-monitor.service vision-rotator.service mirror-retention.service nas-sync.service || true
systemctl stop usb-gadget.service vision-webui.service smbd.service nmbd.service wsdd.service || true
systemctl stop srv-vision_mirror.mount srv-vision_mirror.automount || true

vgchange -ay "$VG" || true

# Backup configs from SSD to RAM before wiping
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
if [[ -f /etc/vision-gw.conf ]]; then
  cp /etc/vision-gw.conf "$BACKUP_DIR/vision-gw.conf"
fi
if [[ -f /etc/vision-nas.creds ]]; then
  cp /etc/vision-nas.creds "$BACKUP_DIR/vision-nas.creds"
fi
if [[ -f "$MIRROR_MOUNT/.state/vision-gw.conf" ]]; then
  cp "$MIRROR_MOUNT/.state/vision-gw.conf" "$BACKUP_DIR/vision-gw.shadow.conf"
fi
if [[ -f "$MIRROR_MOUNT/.state/vision-nas.creds" ]]; then
  cp "$MIRROR_MOUNT/.state/vision-nas.creds" "$BACKUP_DIR/vision-nas.shadow.creds"
fi
if [[ -f "$MIRROR_MOUNT/.state/network.json" ]]; then
  cp "$MIRROR_MOUNT/.state/network.json" "$BACKUP_DIR/network.json"
fi
if [[ -f "$MIRROR_MOUNT/.state/webui.passwd" ]]; then
  cp "$MIRROR_MOUNT/.state/webui.passwd" "$BACKUP_DIR/webui.passwd"
fi
if [[ -f "$MIRROR_MOUNT/.state/webui.secret" ]]; then
  cp "$MIRROR_MOUNT/.state/webui.secret" "$BACKUP_DIR/webui.secret"
fi

if mountpoint -q "$MIRROR_MOUNT"; then
  if ! umount "$MIRROR_MOUNT"; then
    if [[ "$FORCE_UMOUNT" == "true" ]]; then
      if command -v fuser >/dev/null 2>&1; then
        fuser -km "$MIRROR_MOUNT" || true
      fi
      umount "$MIRROR_MOUNT" || umount -l "$MIRROR_MOUNT" || true
    else
      echo "Mirror mount busy: $MIRROR_MOUNT (use --force-umount)" >&2
      exit 1
    fi
  fi
fi
if mountpoint -q "$MIRROR_MOUNT"; then
  echo "Mirror mount still busy after unmount attempts: $MIRROR_MOUNT" >&2
  exit 1
fi
mkfs.ext4 -F "/dev/$VG/$MIRROR_LV"
mkdir -p "$MIRROR_MOUNT"
mount "/dev/$VG/$MIRROR_LV" "$MIRROR_MOUNT"
if ! mountpoint -q "$MIRROR_MOUNT"; then
  echo "Failed to mount mirror LV at $MIRROR_MOUNT" >&2
  exit 1
fi
rm -rf "$MIRROR_MOUNT/.state" || true
mkdir -p "$MIRROR_MOUNT/.state" "$MIRROR_MOUNT/raw" "$MIRROR_MOUNT/bydate"

if [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]; then
  mkdir -p "$USB_PERSIST_BACKING"
fi

# Restore shadow config after wipe (from RAM backup)
if [[ -f "$BACKUP_DIR/vision-gw.shadow.conf" ]]; then
  cp "$BACKUP_DIR/vision-gw.shadow.conf" "$MIRROR_MOUNT/.state/vision-gw.conf"
elif [[ -f "$BACKUP_DIR/vision-gw.conf" ]]; then
  cp "$BACKUP_DIR/vision-gw.conf" "$MIRROR_MOUNT/.state/vision-gw.conf"
fi
if [[ -f "$BACKUP_DIR/vision-nas.shadow.creds" ]]; then
  cp "$BACKUP_DIR/vision-nas.shadow.creds" "$MIRROR_MOUNT/.state/vision-nas.creds"
elif [[ -f "$BACKUP_DIR/vision-nas.creds" ]]; then
  cp "$BACKUP_DIR/vision-nas.creds" "$MIRROR_MOUNT/.state/vision-nas.creds"
fi
if [[ -f "$BACKUP_DIR/network.json" ]]; then
  cp "$BACKUP_DIR/network.json" "$MIRROR_MOUNT/.state/network.json"
fi
if [[ -f "$BACKUP_DIR/webui.passwd" ]]; then
  cp "$BACKUP_DIR/webui.passwd" "$MIRROR_MOUNT/.state/webui.passwd"
fi
if [[ -f "$BACKUP_DIR/webui.secret" ]]; then
  cp "$BACKUP_DIR/webui.secret" "$MIRROR_MOUNT/.state/webui.secret"
fi

for lv in "${USB_LVS[@]}"; do
  dev="/dev/$VG/$lv"
  fs_dev="$dev"
  if command -v sfdisk >/dev/null 2>&1; then
    dump=$(sfdisk -d "$dev" 2>/dev/null || true)
    if [[ -n "$dump" && "$dump" == *"label:"* && "$dump" == *"$dev"* ]]; then
      fs_dev=$(resolve_usb_device "$dev")
    fi
  fi
  mkfs.vfat -F 32 -n "$USB_LABEL" "$fs_dev"
  if [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]; then
    persist_mnt="/mnt/vision_wipe_${lv}"
    safe_mkdir "$persist_mnt"
    if mount -t vfat -o utf8,shortname=mixed,nodev,nosuid,noexec "$fs_dev" "$persist_mnt"; then
      safe_mkdir "$persist_mnt/$USB_PERSIST_DIR"
      umount "$persist_mnt" || true
    fi
  fi
done

systemctl start usb-gadget.service || true
systemctl start smbd.service nmbd.service wsdd.service || true
systemctl start vision-webui.service || true
systemctl start vision-sync.service vision-monitor.service vision-rotator.service || true
systemctl enable --now vision-sync.timer vision-monitor.timer vision-rotator.timer || true

echo "Done."

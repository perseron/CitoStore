#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

lv_name=${1:-}
if [[ -z "$lv_name" ]]; then
  echo "usage: $0 <lv_name>" >&2
  exit 1
fi

active=$(cat /run/vision-usb-active 2>/dev/null || true)
if [[ "$active" == "/dev/$LVM_VG/$lv_name" ]]; then
  echo "refusing to process active LV" >&2
  exit 1
fi

dev="/dev/$LVM_VG/$lv_name"

: "${MIRROR_MOUNT:=/srv/vision_mirror}"
: "${USB_PERSIST_DIR:=aoi_settings}"
: "${USB_PERSIST_BACKING:=$MIRROR_MOUNT/.state/$USB_PERSIST_DIR}"
: "${USB_PERSIST_DURATION_FILE:=$MIRROR_MOUNT/aoi_settings_duration.txt}"

PERSIST_MNT="/mnt/vision_persist_$lv_name"

persist_enabled() {
  [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]
}

persist_sync_dir() {
  local src="$1" dst="$2"
  safe_mkdir "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src" "$dst"
  else
    rm -rf "$dst"
    safe_mkdir "$dst"
    cp -a "$src/." "$dst/"
  fi
}

persist_record_duration() {
  local export_s="$1" import_s="$2" total_s="$3"
  if [[ -n "${USB_PERSIST_DURATION_FILE:-}" ]]; then
    {
      echo "timestamp=$(date -Is)"
      echo "export_seconds=$export_s"
      echo "import_seconds=$import_s"
      echo "total_seconds=$total_s"
    } > "$USB_PERSIST_DURATION_FILE" 2>/dev/null || true
  fi
}

log "fsck FAT32 (read-only check)"
fsck.fat -n "$dev" || true
log "fsck FAT32 (auto-fix)"
fsck.fat -a "$dev" || true

log "offline export"
python3 -m vision_sync.sync --config /etc/vision-gw.conf --dev "$dev" --offline

persist_export_s=0
persist_import_s=0
persist_total_s=0
persist_start=0

if persist_enabled; then
  persist_start=$(date +%s)
  log "persist export: $USB_PERSIST_DIR -> $USB_PERSIST_BACKING"
  safe_mkdir "$PERSIST_MNT"
  if mount -t vfat -o ro,utf8,shortname=mixed,nodev,nosuid,noexec "$dev" "$PERSIST_MNT"; then
    if [[ -d "$PERSIST_MNT/$USB_PERSIST_DIR" ]]; then
      export_start=$(date +%s)
      persist_sync_dir "$PERSIST_MNT/$USB_PERSIST_DIR/" "$USB_PERSIST_BACKING/"
      export_end=$(date +%s)
      persist_export_s=$((export_end - export_start))
    else
      log "persist source missing: $PERSIST_MNT/$USB_PERSIST_DIR"
    fi
    umount "$PERSIST_MNT" || true
  else
    log "persist export mount failed for $dev"
  fi
fi

if blkdiscard "$dev" >/dev/null 2>&1; then
  log "blkdiscard done"
fi

log "reformat FAT32"
mkfs.vfat -F 32 -n "$USB_LABEL" "$dev"

if persist_enabled; then
  log "persist restore: $USB_PERSIST_BACKING -> $USB_PERSIST_DIR"
  safe_mkdir "$PERSIST_MNT"
  if mount -t vfat -o utf8,shortname=mixed,nodev,nosuid,noexec "$dev" "$PERSIST_MNT"; then
    safe_mkdir "$PERSIST_MNT/$USB_PERSIST_DIR"
    if [[ -d "$USB_PERSIST_BACKING" ]]; then
      import_start=$(date +%s)
      persist_sync_dir "$USB_PERSIST_BACKING/" "$PERSIST_MNT/$USB_PERSIST_DIR/"
      import_end=$(date +%s)
      persist_import_s=$((import_end - import_start))
    else
      log "persist backing missing: $USB_PERSIST_BACKING"
    fi
    umount "$PERSIST_MNT" || true
  else
    log "persist restore mount failed for $dev"
  fi
  persist_total_s=$(( $(date +%s) - persist_start ))
  persist_record_duration "$persist_export_s" "$persist_import_s" "$persist_total_s"
fi

log "offline maintenance complete"

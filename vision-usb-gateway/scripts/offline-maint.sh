#!/usr/bin/env bash
set -euo pipefail

# Export a USB LV the AOI no longer sees to the mirror, then reformat it for its
# next turn (FAT check, full offline export, aoi_settings round trip, discard,
# mkfs). Run by the rotator after each switch (offline-maint@<lv>.service), and
# to finish one that was interrupted (usb_maint_marker, common.sh).
#   offline-maint.sh <lv>                export + reformat; skipped if nothing
#                                        is pending for it (already done)
#   offline-maint.sh <lv> --force        export + reformat regardless
#   offline-maint.sh <lv> --format-only  reformat only: an LV with no FAT at
#                                        all (nothing on it to export)

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

lv_name=${1:-}
mode=${2:-}
if [[ -z "$lv_name" ]]; then
  echo "usage: $0 <lv_name> [--force|--format-only]" >&2
  exit 1
fi

: "${MIRROR_MOUNT:=/srv/vision_mirror}"
MARKER=$(usb_maint_marker "$lv_name")
# Export attempts before a drive that cannot be read is recycled anyway.
EXPORT_ATTEMPTS=3

# One switch/export/format at a time (usb_lock): the state below is only
# trusted once it is held.
usb_lock

active=$(cat /run/vision-usb-active 2>/dev/null || true)
if [[ "$active" == "/dev/$LVM_VG/$lv_name" ]]; then
  echo "refusing to process active LV" >&2
  exit 1
fi
if [[ -z "$mode" && ! -e "$MARKER" ]] && mountpoint -q "$MIRROR_MOUNT"; then
  # Already done (the rotator finishes a pending one itself before switching
  # to it; this queued run then has nothing left to do).
  log "offline-maint: nothing pending for $lv_name"
  exit 0
fi
if [[ "$mode" != "--format-only" ]] && ! mountpoint -q "$MIRROR_MOUNT"; then
  # Exporting needs the mirror; formatting without it would destroy the
  # drive's only copy of its images. Kept for when the mirror is back.
  echo "mirror not mounted: $lv_name kept as it is (its images are not exported yet)" >&2
  exit 1
fi

dev="/dev/$LVM_VG/$lv_name"
fs_dev=$(resolve_usb_device "$dev")

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

persist_export_s=0
persist_import_s=0
persist_total_s=0
persist_start=0

if [[ "$mode" != "--format-only" ]]; then
log "fsck FAT32 (read-only check)"
fsck.fat -n "$fs_dev" || true
log "fsck FAT32 (auto-fix)"
fsck.fat -a "$fs_dev" || true

log "offline export"
if ! python3 -m vision_sync.sync --config /etc/vision-gw.conf --dev "$dev" --offline; then
  if ! mountpoint -q "$MIRROR_MOUNT"; then
    echo "mirror gone during the export: $lv_name kept as it is" >&2
    exit 1
  fi
  attempts=$(tr -cd '0-9' < "$MARKER" 2>/dev/null || true)
  attempts=$(( ${attempts:-0} + 1 ))
  if (( attempts < EXPORT_ATTEMPTS )); then
    echo "$attempts" > "$MARKER" || true
    echo "export of $lv_name failed ($attempts/$EXPORT_ATTEMPTS): kept for another try" >&2
    exit 1
  fi
  # A drive that cannot be read (reformatted by someone as exFAT/NTFS, a FAT
  # damaged beyond fsck) would be kept for good — and with it every rotation
  # onto it blocked, until the AOI's drive filled. Availability first: it is
  # recycled, the loss recorded and shown as an error.
  record_export_loss "$dev" "its images could not be read (export failed $attempts times); recycled without them"
fi
fi

if persist_enabled && [[ "$mode" != "--format-only" ]]; then
  persist_start=$(date +%s)
  log "persist export: $USB_PERSIST_DIR -> $USB_PERSIST_BACKING"
  safe_mkdir "$PERSIST_MNT"
if mount -t vfat -o ro,utf8,shortname=mixed,nodev,nosuid,noexec "$fs_dev" "$PERSIST_MNT"; then
    # An EMPTY folder on the drive while the NVMe copy holds settings is a
    # folder that was created bare (old install/clone code), not the AOI
    # deleting all its settings: exporting it (rsync --delete) would erase the
    # copy every drive is restored from. Keep the copy.
    if [[ -d "$PERSIST_MNT/$USB_PERSIST_DIR" && -z "$(ls -A "$PERSIST_MNT/$USB_PERSIST_DIR" 2>/dev/null)" &&
          -n "$(ls -A "$USB_PERSIST_BACKING" 2>/dev/null)" ]]; then
      log "persist export skipped: $USB_PERSIST_DIR on $lv_name is empty, keeping the NVMe copy"
    elif [[ -d "$PERSIST_MNT/$USB_PERSIST_DIR" ]]; then
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

# Save partition table before blkdiscard — thin-pool discard returns all
# blocks (including MBR) to the pool, so reads become zeros.
pt_dump=""
if command -v sfdisk >/dev/null 2>&1; then
  pt_dump=$(sfdisk -d "$dev" 2>/dev/null || true)
fi

# Still not the AOI's drive (the lock keeps the rotator out; checked again
# right before anything is destroyed all the same).
if [[ "$(cat /run/vision-usb-active 2>/dev/null || true)" == "$dev" ]]; then
  echo "refusing to format $lv_name: it is the active drive now" >&2
  exit 1
fi
if blkdiscard "$dev" >/dev/null 2>&1; then
  log "blkdiscard done"
else
  # Thin-pool blocks not returned: the pool fills with every rotation's old data.
  log "WARNING: blkdiscard failed on $dev (thin-pool space not reclaimed)"
fi

# Restore partition table destroyed by blkdiscard on thin LVs.
if [[ -n "$pt_dump" && "$pt_dump" == *"label:"* ]]; then
  echo "$pt_dump" | sfdisk --force "$dev" >/dev/null 2>&1 || true
  # Unique MBR disk identifier per reformat.
  disk_id=$(printf '0x%08x' "$(( RANDOM * 65536 + RANDOM ))")
  sfdisk --disk-id "$dev" "$disk_id" >/dev/null 2>&1 || true
  if [[ -x /sbin/partx ]]; then
    /sbin/partx -u "$dev" >/dev/null 2>&1 || true
  fi
fi

log "reformat FAT32"
# Each reformat MUST get a unique FAT volume serial so the host OS
# (Windows) does not confuse volumes and serve stale cached directory
# data.  USB_VOLUME_SERIAL is intentionally ignored.
vol_serial=$(printf '%04X%04X' "$((RANDOM))" "$((RANDOM))")
mkfs_opts=(-F 32 -n "$USB_LABEL" -i "$vol_serial")
mkfs.vfat "${mkfs_opts[@]}" "$fs_dev"

if persist_enabled; then
  (( persist_start )) || persist_start=$(date +%s)
  log "persist restore: $USB_PERSIST_BACKING -> $USB_PERSIST_DIR"
  safe_mkdir "$PERSIST_MNT"
if mount -t vfat -o utf8,shortname=mixed,nodev,nosuid,noexec "$fs_dev" "$PERSIST_MNT"; then
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

# Exported and reformatted: ready for its next turn.
rm -f "$MARKER"
log "offline maintenance complete"

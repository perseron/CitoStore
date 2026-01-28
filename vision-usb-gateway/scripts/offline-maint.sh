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

log "fsck FAT32 (read-only check)"
fsck.fat -n "$dev" || true
log "fsck FAT32 (auto-fix)"
fsck.fat -a "$dev" || true

log "offline export"
python3 -m vision_sync.sync --config /etc/vision-gw.conf --dev "$dev" --offline

if blkdiscard "$dev" >/dev/null 2>&1; then
  log "blkdiscard done"
fi

log "reformat FAT32"
mkfs.vfat -F 32 -n "$USB_LABEL" "$dev"

log "offline maintenance complete"
#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

VG="${LVM_VG:-vg0}"
USB_LVS=("${USB_LVS[@]:-usb_0 usb_1 usb_2}")
USB_LABEL="${USB_LABEL:-VISIONUSB}"
: "${USB_PERSIST_DIR:=aoi_settings}"

active=$(cat /run/vision-usb-active 2>/dev/null || true)
if [[ -z "$active" ]]; then
  echo "active device file missing" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage:
  clone-usb-format.sh --i-know-what-im-doing

Clones the active USB LV format to all inactive USB LVs.
If the active LV has a partition table, it is replicated and the first partition is formatted.
EOF
}

CONFIRM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --i-know-what-im-doing)
      CONFIRM=true
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

# Remove stale LVM snapshots that reference our USB LVs.  Orphaned
# snapshots (e.g. usb_bf_*, usb_sync_snap) keep LVs in snapshot-origin
# mode and prevent clean reformatting / offline-maint.
if command -v lvs >/dev/null 2>&1; then
  while IFS=$'\t' read -r snap_lv snap_origin; do
    snap_lv=$(echo "$snap_lv" | xargs)
    snap_origin=$(echo "$snap_origin" | xargs)
    [[ -n "$snap_lv" ]] || continue
    # Only remove snapshots whose origin is one of our USB LVs.
    for check_lv in "${USB_LVS[@]}"; do
      if [[ "$snap_origin" == "$check_lv" ]]; then
        log "removing stale snapshot: $VG/$snap_lv (origin=$snap_origin)"
        lvremove -y "$VG/$snap_lv" 2>/dev/null || true
        break
      fi
    done
  done < <(lvs --noheadings --separator $'\t' -o lv_name,origin "$VG" 2>/dev/null \
           | while IFS=$'\t' read -r n o; do
               o=$(echo "$o" | xargs)
               [[ -n "$o" ]] && printf '%s\t%s\n' "$n" "$o"
             done || true)
fi

log "cloning USB format from $active"

table_dump=""
if command -v sfdisk >/dev/null 2>&1; then
  table_dump=$(sfdisk -d "$active" 2>/dev/null || true)
fi

has_part_table=false
if [[ -n "$table_dump" && "$table_dump" == *"label:"* && "$table_dump" == *"$active"* ]]; then
  has_part_table=true
fi

for lv in "${USB_LVS[@]}"; do
  dev="/dev/$VG/$lv"
  if [[ "$dev" == "$active" ]]; then
    continue
  fi

  log "formatting $dev"
  if [[ "$has_part_table" == "true" ]]; then
    # Remove existing partition mappings so sfdisk can repartition.
    if command -v kpartx >/dev/null 2>&1; then
      kpartx -d "$dev" >/dev/null 2>&1 || true
    elif [[ -x /sbin/partx ]]; then
      /sbin/partx -d "$dev" >/dev/null 2>&1 || true
    fi
    if command -v wipefs >/dev/null 2>&1; then
      wipefs -a "$dev" >/dev/null 2>&1 || true
    fi
    sed_active=$(printf '%s' "$active" | sed -e 's/[\/&]/\\&/g')
    sed_dev=$(printf '%s' "$dev" | sed -e 's/[\/&]/\\&/g')
    dump_dev=$(printf '%s\n' "$table_dump" | sed -e "s#^device: .*#device: $dev#" -e "s#^${sed_active}#${sed_dev}#")
    echo "$dump_dev" | sfdisk --wipe always "$dev" >/dev/null
    if [[ -x /sbin/partx ]]; then
      /sbin/partx -u "$dev" >/dev/null 2>&1 || true
    fi
    fs_dev=$(resolve_usb_device "$dev")
  else
    if command -v wipefs >/dev/null 2>&1; then
      wipefs -a "$dev" >/dev/null 2>&1 || true
    fi
    fs_dev="$dev"
  fi

  mkfs_opts=(-F 32 -n "$USB_LABEL")
  if [[ -n "${USB_VOLUME_SERIAL:-}" ]]; then
    mkfs_opts+=(-i "$USB_VOLUME_SERIAL")
  fi
  mkfs.vfat "${mkfs_opts[@]}" "$fs_dev"

  if [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]; then
    mnt="/mnt/vision_clone_${lv}"
    safe_mkdir "$mnt"
    if mount -t vfat -o utf8,shortname=mixed,nodev,nosuid,noexec "$fs_dev" "$mnt"; then
      safe_mkdir "$mnt/$USB_PERSIST_DIR"
      umount "$mnt" || true
    fi
  fi
done

log "clone complete"

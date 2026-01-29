#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

SIZE=""
VG="${LVM_VG:-vg0}"
POOL="${THINPOOL_LV:-usbpool}"
LABEL="${USB_LABEL:-VISIONUSB}"
LVS=()
FORCE=false
DRY_RUN=false
UPDATE_CONFIG=false

usage() {
  cat <<'EOF'
Usage:
  resize-usb-lvs.sh --size 4G [--vg vg0] [--pool usbpool] [--label VISIONUSB]
                    [--lvs "usb_0 usb_1 usb_2"] [--force] [--dry-run]

Recreates thin LVs at the new size and reformats them as FAT32.
WARNING: This destroys data on the USB LVs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size)
      SIZE="$2"
      shift 2
      ;;
    --vg)
      VG="$2"
      shift 2
      ;;
    --pool)
      POOL="$2"
      shift 2
      ;;
    --label)
      LABEL="$2"
      shift 2
      ;;
    --lvs)
      IFS=' ' read -r -a LVS <<< "$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --update-config)
      UPDATE_CONFIG=true
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

if [[ -z "$SIZE" ]]; then
  echo "--size is required (e.g. 4G)" >&2
  exit 1
fi

if [[ ${#LVS[@]} -eq 0 ]]; then
  LVS=("${USB_LVS[@]}")
fi

if [[ ${#LVS[@]} -eq 0 ]]; then
  LVS=(usb_0)
fi

SWITCH_CMD="$(dirname "${BASH_SOURCE[0]}")/usb-gadget.sh"

active="$(cat /run/vision-usb-active 2>/dev/null || true)"

ensure_not_active() {
  local lv="$1"
  local dev="/dev/$VG/$lv"
  if [[ "$active" == "$dev" ]]; then
    if [[ "$FORCE" != "true" ]]; then
      echo "refusing to remove active LV: $dev (use --force to switch)" >&2
      exit 1
    fi
    log "active LV is $lv, switching gadget to next LV"
    if [[ "$DRY_RUN" != "true" ]]; then
      /bin/bash "$SWITCH_CMD" switch
    fi
    active="$(cat /run/vision-usb-active 2>/dev/null || true)"
    if [[ "$active" == "$dev" ]]; then
      echo "active LV is still $dev after switch; aborting" >&2
      exit 1
    fi
  fi
}

echo "Recreating USB LVs: ${LVS[*]} (size=$SIZE, vg=$VG, pool=$POOL, label=$LABEL)"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY-RUN: no changes will be made"
fi

for lv in "${LVS[@]}"; do
  ensure_not_active "$lv"
  dev="/dev/$VG/$lv"
  log "recreate $dev"
  if [[ "$DRY_RUN" != "true" ]]; then
    lvremove -y "$dev" || true
    lvcreate -V "$SIZE" -T "$VG/$POOL" -n "$lv"
    mkfs.vfat -F 32 -n "$LABEL" "$dev"
  fi
done

if [[ "$UPDATE_CONFIG" == "true" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY-RUN: would update /etc/vision-gw.conf: USB_LV_SIZE=$SIZE"
  else
    if [[ -w /etc/vision-gw.conf ]]; then
      if grep -q '^USB_LV_SIZE=' /etc/vision-gw.conf; then
        sed -i "s/^USB_LV_SIZE=.*/USB_LV_SIZE=$SIZE/" /etc/vision-gw.conf
      else
        echo "USB_LV_SIZE=$SIZE" >> /etc/vision-gw.conf
      fi
      echo "Updated /etc/vision-gw.conf: USB_LV_SIZE=$SIZE"
    else
      echo "Cannot write /etc/vision-gw.conf (read-only). Update manually: USB_LV_SIZE=$SIZE" >&2
      exit 1
    fi
  fi
else
  echo "Remember to update /etc/vision-gw.conf: USB_LV_SIZE=$SIZE"
fi

echo "Done."

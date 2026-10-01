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
SKIP_SYNC=false
: "${USB_PERSIST_DIR:=aoi_settings}"
: "${MIRROR_MOUNT:=/srv/vision_mirror}"
: "${USB_PERSIST_BACKING:=$MIRROR_MOUNT/.state/$USB_PERSIST_DIR}"

usage() {
  cat <<'EOF'
Usage:
  resize-usb-lvs.sh --size 4G [--vg vg0] [--pool usbpool] [--label VISIONUSB]
                    [--lvs "usb_0 usb_1 usb_2"] [--force] [--dry-run]
                    [--update-config] [--skip-sync]

Recreates thin LVs at the new size (whole M or G) and reformats them as FAT32.
WARNING: This destroys data on the USB LVs. A sync to the mirror runs first
(--skip-sync to skip it); the AOI's settings folder is put back on each LV.
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
    --skip-sync)
      SKIP_SYNC=true
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
# Validated BEFORE anything is removed: an invalid size ("4GB", "0G") used to
# fail lvcreate only after lvremove had already deleted the first LV. It is
# also written into the shell-sourced config, so nothing but digits + unit.
SIZE=${SIZE^^}
if [[ ! "$SIZE" =~ ^[1-9][0-9]{0,6}[MG]$ ]]; then
  echo "invalid size '$SIZE': use a whole number of M or G, e.g. 16G or 512M" >&2
  exit 1
fi

if [[ ${#LVS[@]} -eq 0 ]]; then
  LVS=("${USB_LVS[@]}")
fi

if [[ ${#LVS[@]} -eq 0 ]]; then
  LVS=(usb_0)
fi

SWITCH_CMD="$(dirname "${BASH_SOURCE[0]}")/usb-gadget.sh"

# All LVs must fit the thin pool. Over-committed, the AOI keeps writing after
# the pool is physically full, and a full thin pool fails writes on EVERY LV
# (and can corrupt them) — the 80 % rotation threshold is per LV, not per pool.
to_bytes() {
  local n=${1%?}
  case ${1: -1} in
    M) echo $((n * 1024 * 1024)) ;;
    G) echo $((n * 1024 * 1024 * 1024)) ;;
  esac
}
size_bytes=$(to_bytes "$SIZE")
if ((size_bytes < 64 * 1024 * 1024)); then
  echo "size $SIZE too small for FAT32 (minimum 64M); nothing changed" >&2
  exit 1
fi
pool_bytes=$(lvs --noheadings --units b --nosuffix -o lv_size "$VG/$POOL" 2>/dev/null | tr -d ' ' | cut -d. -f1)
if [[ -z "$pool_bytes" ]]; then
  echo "thin pool $VG/$POOL not found; nothing changed" >&2
  exit 1
fi
need_bytes=$((size_bytes * ${#LVS[@]}))
if ((need_bytes > pool_bytes)); then
  echo "${#LVS[@]} x $SIZE = $((need_bytes / 1048576))M does not fit the USB pool ($((pool_bytes / 1048576))M); nothing changed" >&2
  exit 1
fi

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

# No sync may run while the LVs are swapped underneath it; put back only the
# timers that were running (maintenance mode keeps them stopped on purpose).
timers_were_active=()
if [[ "$DRY_RUN" != "true" ]]; then
  for t in vision-sync.timer vision-sync-fast.timer vision-rotator.timer; do
    if systemctl is-active --quiet "$t"; then
      timers_were_active+=("$t")
    fi
  done
fi
on_exit() {
  local rc=$?
  if ((rc != 0)) && [[ "$DRY_RUN" != "true" ]]; then
    # A half-done resize leaves an LV removed: recreate what is missing (at the
    # configured size) now, instead of leaving the AOI without a drive until
    # the next boot's health check does it.
    log "resize FAILED (rc=$rc); recreating any missing USB LV"
    bash "$GATEWAY_HOME/install/30_setup_nvme_lvm.sh" >/dev/null 2>&1 || log "LV self-heal failed; reboot to retry"
  fi
  if ((${#timers_were_active[@]})); then
    systemctl start "${timers_were_active[@]}" || true
  fi
}
trap on_exit EXIT

if [[ "$DRY_RUN" != "true" ]]; then
  if ((${#timers_were_active[@]})); then
    systemctl stop "${timers_were_active[@]}" || true
  fi
  # Mirror what the AOI has written so far: the LVs are about to be emptied.
  if [[ "$SKIP_SYNC" != "true" ]]; then
    log "syncing the USB drive to the mirror before the resize"
    if ! systemctl start vision-sync.service; then
      echo "sync to the mirror failed; nothing changed (fix the sync, or use --skip-sync to accept losing unsynced images)" >&2
      exit 1
    fi
  fi
  # The rotator runs in vision-sync's ExecStopPost, after the start job has
  # returned: wait it out, or it switches/reformats LVs under our feet.
  for ((i = 0; i < 2400; i++)); do
    case $(systemctl show -p ActiveState --value vision-sync.service 2>/dev/null) in
      activating | deactivating | reloading) sleep 1 ;;
      *) break ;;
    esac
  done
fi

for lv in "${LVS[@]}"; do
  ensure_not_active "$lv"
  dev="/dev/$VG/$lv"
  log "recreate $dev"
  if [[ "$DRY_RUN" != "true" ]]; then
    # Not "|| true": an LV that cannot be removed (still open) made lvcreate
    # fail with "already exists" — say what actually went wrong.
    if lvs "$dev" >/dev/null 2>&1 && ! lvremove -y "$dev"; then
      echo "cannot remove $dev (in use?); stopping here" >&2
      exit 1
    fi
    lvcreate -V "$SIZE" -T "$VG/$POOL" -n "$lv"
    vol_serial=$(printf '%04X%04X' "$((RANDOM))" "$((RANDOM))")
    mkfs.vfat -F 32 -n "$LABEL" -i "$vol_serial" "$dev"
    if [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]; then
      persist_mnt="/mnt/vision_resize_${lv}"
      safe_mkdir "$persist_mnt"
      if mount -t vfat -o utf8,shortname=mixed,nodev,nosuid,noexec "$dev" "$persist_mnt"; then
        safe_mkdir "$persist_mnt/$USB_PERSIST_DIR"
        # Put the AOI's own settings back (it used to get an empty folder).
        if [[ -d "$USB_PERSIST_BACKING" ]]; then
          cp -a "$USB_PERSIST_BACKING/." "$persist_mnt/$USB_PERSIST_DIR/" 2>/dev/null || true
        fi
        umount "$persist_mnt" || true
      fi
    fi
  fi
done

if [[ "$UPDATE_CONFIG" == "true" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY-RUN: would set USB_LV_SIZE=$SIZE in the config"
  else
    # Shadow (NVMe) + /etc: /etc alone is a RAM copy under the overlay, so the
    # unit "forgot" the new size at the next boot (WebUI showed the old one,
    # and a self-heal/rebuild used it).
    set_conf_value USB_LV_SIZE "$SIZE"
    echo "Updated the config: USB_LV_SIZE=$SIZE"
  fi
else
  echo "Remember to update /etc/vision-gw.conf: USB_LV_SIZE=$SIZE"
fi

echo "Done."

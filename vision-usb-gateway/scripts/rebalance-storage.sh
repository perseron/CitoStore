#!/usr/bin/env bash
set -euo pipefail

# Expert/offline tool — deliberately NOT in the WebUI any more. It removes and
# recreates the mirror LV on the running unit, and a live teardown of the in-use
# NVMe is unreliable (a held LV cannot be removed until a reboot; see
# factory-reset.sh, which does its rebuild at early boot for that reason). From
# the WebUI it also could not change the sizes it rebuilds from, and its button
# promised a "rebalance" while it erased every image.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

VG="${LVM_VG:-vg0}"
MIRROR_LV="${MIRROR_LV:-mirror}"
MIRROR_MOUNT="${MIRROR_MOUNT:-/srv/vision_mirror}"
POOL="${THINPOOL_LV:-usbpool}"
POOL_SIZE="${THINPOOL_SIZE:-40G}"
POOL_META="${THINPOOL_META_SIZE:-2G}"
USB_LABEL="${USB_LABEL:-VISIONUSB}"
USB_LV_SIZE="${USB_LV_SIZE:-4G}"
USB_LVS=("${USB_LVS[@]:-usb_0 usb_1 usb_2}")
UNALLOCATED="${UNALLOCATED_GB:-20G}"
: "${USB_PERSIST_DIR:=aoi_settings}"
: "${USB_PERSIST_BACKING:=$MIRROR_MOUNT/.state/$USB_PERSIST_DIR}"

CONFIRM=false
DRY_RUN=false
UPDATE_CONFIG=false
FORCE_UMOUNT=false

usage() {
  cat <<'EOF'
Usage:
  rebalance-storage.sh --i-know-what-im-doing [--dry-run] [--update-config] [--force-umount]

Rebuilds mirror + thinpool + USB LVs based on /etc/vision-gw.conf.
All captured data (images) is destroyed; settings and passwords in .state are
carried over. Prefer a maintenance window: stop clients of the mirror first.

Optional: set UNALLOCATED_GB=20G in config or env to reserve free space.
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
    --update-config)
      UPDATE_CONFIG=true
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

MIRROR_SIZE=$(VG="$VG" POOL_SIZE="$POOL_SIZE" POOL_META="$POOL_META" USB_LV_SIZE="$USB_LV_SIZE" UNALLOCATED="$UNALLOCATED" USB_COUNT="${#USB_LVS[@]}" \
  python3 - <<'PY'
import os, subprocess, sys, re

def num(s: str) -> int:
    m = re.match(r"^([0-9.]+)([KMGTP]?)$", s.strip(), re.I)
    if not m:
        raise SystemExit(f"bad size: {s}")
    val = float(m.group(1))
    unit = m.group(2).upper()
    mult = {"":1,"K":1024,"M":1024**2,"G":1024**3,"T":1024**4,"P":1024**5}[unit]
    return int(val * mult)

def fmt(bytes_: int) -> str:
    return f"{bytes_ // (1024**3)}G"

VG = os.environ["VG"]
POOL_SIZE = os.environ["POOL_SIZE"]
POOL_META = os.environ["POOL_META"]
USB_LV_SIZE = os.environ["USB_LV_SIZE"]
UNALLOCATED = os.environ["UNALLOCATED"]

vg_size = subprocess.check_output(["vgs", "--units", "b", "--nosuffix", "-o", "vg_size", VG]).decode().splitlines()[-1].strip()
vg_size = int(float(vg_size))

pool = num(POOL_SIZE)
meta = num(POOL_META)
unalloc = num(UNALLOCATED)
usb_lv = num(USB_LV_SIZE)
usb_count = int(os.environ["USB_COUNT"])

mirror = vg_size - pool - meta - unalloc
if mirror <= 0:
    raise SystemExit("mirror size <= 0 (adjust sizes)")

print(fmt(mirror))
PY
)

echo "Rebalancing storage:"
echo "  VG: $VG"
echo "  Mirror LV: /dev/$VG/$MIRROR_LV -> $MIRROR_MOUNT (size=$MIRROR_SIZE)"
echo "  Thin pool: $POOL (size=$POOL_SIZE, meta=$POOL_META)"
echo "  USB LVs: ${USB_LVS[*]} (size=$USB_LV_SIZE)"
echo "  Unallocated: $UNALLOCATED"
if [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]; then
  echo "  USB persist dir: $USB_PERSIST_DIR"
  echo "  USB persist backing: $USB_PERSIST_BACKING"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY-RUN: no changes will be made"
  exit 0
fi

BACKUP_DIR=/run/vision-rebalance-backup
restart_stack() {
  systemctl start srv-vision_mirror.mount || true
  systemctl start usb-gadget.service smbd.service nmbd.service vision-webui.service || true
  # Not the rotator timer: it is off by design (the rotator runs after each sync).
  systemctl start vision-sync.timer vision-monitor.timer || true
}
# A failure part-way used to exit with the gadget, sync and timers stopped (and,
# after the mkfs, an empty .state: no passwords, no config) until a reboot.
on_exit() {
  local rc=$?
  ((rc != 0)) || return 0
  log "rebalance FAILED (rc=$rc); restoring what can be restored"
  if mountpoint -q "$MIRROR_MOUNT" && [[ -d "$BACKUP_DIR/state" && ! -e "$MIRROR_MOUNT/.state/vision-gw.conf" ]]; then
    state_restore "$BACKUP_DIR/state" "$MIRROR_MOUNT/.state" || true
  fi
  restart_stack
}
trap on_exit EXIT

# Settings, passwords, the SMB passdb, AOI settings: kept in RAM across the mkfs.
state_backup "$MIRROR_MOUNT/.state" "$BACKUP_DIR/state"

systemctl stop vision-sync.timer vision-sync-fast.timer vision-monitor.timer vision-rotator.timer mirror-retention.timer nas-sync.timer || true
systemctl stop vision-sync.service vision-monitor.service vision-rotator.service mirror-retention.service nas-sync.service || true
systemctl stop usb-gadget.service smbd.service nmbd.service vsftpd-mirror.service || true
# Through systemd, so the Samba bind of .state/samba (and anything else that
# requires the mount) is released first.
systemctl stop srv-vision_mirror.mount || true

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

for lv in "${USB_LVS[@]}"; do
  lvremove -y "/dev/$VG/$lv" || true
done

lvremove -y "/dev/$VG/$POOL" || true
lvremove -y "/dev/$VG/${POOL}_tdata" || true
lvremove -y "/dev/$VG/${POOL}_tmeta" || true
lvremove -y "/dev/$VG/$MIRROR_LV" || true

lvcreate -L "$MIRROR_SIZE" -n "$MIRROR_LV" "$VG"
mkfs.ext4 -F "/dev/$VG/$MIRROR_LV"
mount "/dev/$VG/$MIRROR_LV" "$MIRROR_MOUNT"
mkdir -p "$MIRROR_MOUNT/.state" "$MIRROR_MOUNT/raw" "$MIRROR_MOUNT/bydate"
state_restore "$BACKUP_DIR/state" "$MIRROR_MOUNT/.state"

if [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]; then
  mkdir -p "$USB_PERSIST_BACKING"
fi

lvcreate -L "$POOL_SIZE" --poolmetadatasize "$POOL_META" --type thin-pool -n "$POOL" "$VG"

for lv in "${USB_LVS[@]}"; do
  lvcreate -V "$USB_LV_SIZE" -T "$VG/$POOL" -n "$lv"
  vol_serial=$(printf '%04X%04X' "$((RANDOM))" "$((RANDOM))")
  mkfs_opts=(-F 32 -n "$USB_LABEL" -i "$vol_serial")
  mkfs.vfat "${mkfs_opts[@]}" "/dev/$VG/$lv"
  if [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]; then
    persist_mnt="/mnt/vision_rebalance_${lv}"
    safe_mkdir "$persist_mnt"
    if mount -t vfat -o utf8,shortname=mixed,nodev,nosuid,noexec "/dev/$VG/$lv" "$persist_mnt"; then
      safe_mkdir "$persist_mnt/$USB_PERSIST_DIR"
      if [[ -d "$USB_PERSIST_BACKING" ]]; then
        cp -a "$USB_PERSIST_BACKING/." "$persist_mnt/$USB_PERSIST_DIR/" 2>/dev/null || true
      fi
      umount "$persist_mnt" || true
    fi
  fi
done

if [[ "$UPDATE_CONFIG" == "true" ]]; then
  # Shadow + /etc (set_conf_value): /etc alone is lost at the next boot.
  set_conf_value MIRROR_SIZE "$MIRROR_SIZE"
  set_conf_value THINPOOL_SIZE "$POOL_SIZE"
  set_conf_value THINPOOL_META_SIZE "$POOL_META"
  set_conf_value USB_LV_SIZE "$USB_LV_SIZE"
  set_conf_value UNALLOCATED_GB "$UNALLOCATED"
fi

# The mirror was mounted by hand above; hand it back to systemd's mount unit.
umount "$MIRROR_MOUNT" || true
restart_stack

echo "Done."

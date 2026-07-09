#!/usr/bin/env bash
set -euo pipefail

# Provision (or re-provision) this unit from a config bundle (.citostore).
# The bundle carries everything: vision-gw.conf, WebUI/SMB/NAS secrets, the
# Samba passdb, and aoi_settings. This is how a blank replacement unit becomes
# a drop-in for a failed one.
#
# The USB LV size/count (the Win98 host drives) are taken verbatim from the
# bundle; the mirror is resized to fill whatever NVMe this unit actually has,
# so a replacement with a different-sized NVMe still works.
#
# Usage:
#   provision-from-bundle.sh <bundle.citostore> --plan
#       Print the provisioning plan (target NVMe, computed layout) as JSON. Safe.
#   provision-from-bundle.sh <bundle.citostore> --provision --confirm
#       DESTRUCTIVE: wipe + repartition the NVMe and apply the bundle.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

BUNDLE="${1:-}"
MODE="plan"
CONFIRM=false
for arg in "${@:2}"; do
  case "$arg" in
    --plan) MODE="plan" ;;
    --provision) MODE="provision" ;;
    --confirm) CONFIRM=true ;;
  esac
done

if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "usage: $0 <bundle.citostore> --plan | --provision --confirm" >&2
  exit 1
fi

GATEWAY_HOME=$(cd "$SCRIPT_DIR/.." && pwd)
MIN_MIRROR_GIB=20

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$BUNDLE" -C "$STAGE" 2>/dev/null || { echo "invalid bundle (not a .citostore archive)" >&2; exit 1; }

BUNDLE_CONF="$STAGE/etc/vision-gw.conf"
if [[ ! -f "$BUNDLE_CONF" ]]; then
  echo "bundle missing vision-gw.conf" >&2
  exit 1
fi

# Pull the fixed values from the bundle config in a clean subshell.
read_conf_vars() {
  (
    set +u
    # shellcheck source=/dev/null
    source "$BUNDLE_CONF"
    echo "NVME_DEVICE=${NVME_DEVICE:-/dev/nvme0n1}"
    echo "LVM_VG=${LVM_VG:-vg0}"
    echo "MIRROR_MOUNT=${MIRROR_MOUNT:-/srv/vision_mirror}"
    echo "SYNC_MOUNT=${SYNC_MOUNT:-/mnt/vision_snap}"
    echo "USB_LV_SIZE=${USB_LV_SIZE:-16G}"
    echo "USB_LV_COUNT=${#USB_LVS[@]}"
  )
}
eval "$(read_conf_vars)"
[[ "$USB_LV_COUNT" -eq 0 ]] && USB_LV_COUNT=1

if [[ ! -b "$NVME_DEVICE" ]]; then
  echo "nvme device not found: $NVME_DEVICE" >&2
  exit 1
fi

# --- size adaptation: USB LVs fixed, mirror fills the rest of THIS NVMe ---
compute_plan() {
  local dev_bytes usb_gib
  dev_bytes=$(blockdev --getsize64 "$NVME_DEVICE")
  usb_gib=$(printf '%s' "$USB_LV_SIZE" | tr -dc '0-9')
  [[ -z "$usb_gib" ]] && usb_gib=16
  python3 - "$dev_bytes" "$USB_LV_COUNT" "$usb_gib" "$MIN_MIRROR_GIB" <<'PY'
import sys
dev_bytes, n, s, min_mirror = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
gib = 1024**3
total = dev_bytes // gib
# 1 GiB for the 1MiB partition offset + LVM/PV metadata + rounding safety.
usable = total - 1
usbpool = n * s + s                 # LVs + one LV of headroom for snapshot COW
meta = 1
reserve = max(2, usable // 100)     # ~1% safety, min 2 GiB
mirror = usable - usbpool - meta - reserve
ok = mirror >= min_mirror
print(f"NVME_TOTAL_GIB={total}")
print(f"USB_LV_SIZE_GIB={s}")
print(f"USB_LV_COUNT={n}")
print(f"USBPOOL_GIB={usbpool}")
print(f"META_GIB={meta}")
print(f"RESERVE_GIB={reserve}")
print(f"MIRROR_GIB={mirror}")
print(f"PLAN_OK={'true' if ok else 'false'}")
PY
}
eval "$(compute_plan)"

emit_plan_json() {
  cat <<EOF
{
  "nvme_device": "$NVME_DEVICE",
  "nvme_total_gib": $NVME_TOTAL_GIB,
  "usb_lv_size_gib": $USB_LV_SIZE_GIB,
  "usb_lv_count": $USB_LV_COUNT,
  "usbpool_gib": $USBPOOL_GIB,
  "meta_gib": $META_GIB,
  "reserve_gib": $RESERVE_GIB,
  "mirror_gib": $MIRROR_GIB,
  "min_mirror_gib": $MIN_MIRROR_GIB,
  "ok": $PLAN_OK
}
EOF
}

if [[ "$MODE" == "plan" ]]; then
  emit_plan_json
  exit 0
fi

# ---------------- provisioning (destructive) ----------------
if [[ "$PLAN_OK" != "true" ]]; then
  echo "NVMe too small: computed mirror ${MIRROR_GIB}G < ${MIN_MIRROR_GIB}G minimum." >&2
  echo "Reduce USB_LV_SIZE/USB_LVS in the bundle config and retry." >&2
  exit 1
fi
if [[ "$CONFIRM" != "true" ]]; then
  echo "refusing destructive provision without --confirm" >&2
  exit 1
fi

log "PROVISION: wiping $NVME_DEVICE and applying bundle"
log "  layout: mirror=${MIRROR_GIB}G usbpool=${USBPOOL_GIB}G meta=${META_GIB}G usb_lv=${USB_LV_SIZE_GIB}G x${USB_LV_COUNT}"

# 1) Write the bundle config to /etc with adapted sizes so 30_setup uses them.
install -D -m 0644 "$BUNDLE_CONF" /etc/vision-gw.conf
sed -i \
  -e "s/^MIRROR_SIZE=.*/MIRROR_SIZE=${MIRROR_GIB}G/" \
  -e "s/^THINPOOL_SIZE=.*/THINPOOL_SIZE=${USBPOOL_GIB}G/" \
  -e "s/^THINPOOL_META_SIZE=.*/THINPOOL_META_SIZE=${META_GIB}G/" \
  /etc/vision-gw.conf
if grep -q '^GATEWAY_HOME=' /etc/vision-gw.conf; then
  sed -i "s#^GATEWAY_HOME=.*#GATEWAY_HOME=$GATEWAY_HOME#" /etc/vision-gw.conf
fi

# 2) Tear down any existing setup so the NVMe can be repartitioned. On a blank
#    replacement unit these are no-ops; on a re-provision they free the device.
log "tearing down existing setup"
systemctl stop vision-sync.timer vision-sync-fast.timer vision-monitor.timer \
  vision-rotator.timer mirror-retention.timer 2>/dev/null || true
systemctl stop smbd nmbd usb-gadget.service 2>/dev/null || true
# The WebUI holds .state open; stop it so the mirror can unmount. It is
# restarted at the end (or on the next boot).
systemctl stop vision-webui.service 2>/dev/null || true
bash "$GATEWAY_HOME/scripts/usb-gadget.sh" stop 2>/dev/null || true
for mp in /var/lib/samba "$SYNC_MOUNT" "$MIRROR_MOUNT"; do
  umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
done
sleep 1
lvchange -an "$LVM_VG" 2>/dev/null || true
vgchange -an "$LVM_VG" 2>/dev/null || true
# Fallback: force-remove any lingering mappings for this VG so the PV frees up.
for d in $(dmsetup ls 2>/dev/null | awk -v vg="$LVM_VG" '$1 ~ "^"vg"-" {print $1}'); do
  dmsetup remove -f "$d" 2>/dev/null || true
done

# 3) Wipe + partition the NVMe with the adapted layout.
bash "$GATEWAY_HOME/install/30_setup_nvme_lvm.sh" --wipe

# 3) Ensure the mirror is mounted and .state exists.
mountpoint -q "$MIRROR_MOUNT" || mount "$MIRROR_MOUNT" || mount -a
STATE_DIR="$MIRROR_MOUNT/.state"
safe_mkdir "$STATE_DIR"

# 4) Config becomes the authoritative shadow copy.
cp /etc/vision-gw.conf "$STATE_DIR/vision-gw.conf"
cp /etc/vision-gw.conf "$STATE_DIR/vision-gw.conf.last-good"

# 5) Restore secrets + AOI settings from the bundle.
for f in webui.passwd webui.secret vision-nas.creds; do
  if [[ -f "$STAGE/state/$f" ]]; then
    install -m 0600 "$STAGE/state/$f" "$STATE_DIR/$f"
    log "restored $f"
  fi
done
[[ -f "$STAGE/etc/vision-nas.creds" ]] && install -m 0600 "$STAGE/etc/vision-nas.creds" /etc/vision-nas.creds
if [[ -d "$STAGE/state/aoi_settings" ]]; then
  rm -rf "$STATE_DIR/aoi_settings"
  cp -a "$STAGE/state/aoi_settings" "$STATE_DIR/aoi_settings"
  log "restored aoi_settings"
fi

# 6) Apply config (promotes shadow, configures Samba incl. the persist bind mount).
bash "$GATEWAY_HOME/scripts/apply-shadow-config.sh"

# 7) Restore the Samba passdb onto the now-bind-mounted persistent location so
#    the SMB users/passwords come across (Samba was just seeded with defaults).
if [[ -f "$STAGE/samba/passdb.tdb" ]] && mountpoint -q /var/lib/samba; then
  install -m 0600 "$STAGE/samba/passdb.tdb" /var/lib/samba/private/passdb.tdb
  SMB_USER=$(grep -E '^SMB_USER=' /etc/vision-gw.conf | cut -d= -f2 || echo smbuser)
  smbpasswd -e "${SMB_USER:-smbuser}" >/dev/null 2>&1 || true
  systemctl restart smbd nmbd 2>/dev/null || true
  log "restored Samba passdb (SMB users/passwords carried over)"
fi

# 8) Bring the stack up.
systemctl start usb-gadget.service 2>/dev/null || true
systemctl start vision-sync.timer 2>/dev/null || true
systemctl restart vision-webui.service 2>/dev/null || true

log "PROVISION complete: unit provisioned from bundle"
emit_plan_json

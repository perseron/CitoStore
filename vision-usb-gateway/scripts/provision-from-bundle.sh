#!/usr/bin/env bash
set -euo pipefail

# Provision (or re-provision) this unit from a config bundle (.citostore).
# The bundle carries everything: vision-gw.conf, WebUI/SMB/NAS secrets, the
# Samba passdb, and aoi_settings. This is how a blank replacement unit becomes
# a drop-in for a failed one.
#
# The USB LV size/count (the Win98 host drives) are taken verbatim from the
# bundle; the mirror fills whatever NVMe this unit actually has, so a
# replacement with a different-sized NVMe still works.
#
# Two paths:
#   reuse  This unit already has its NVMe layout — every unit does once its
#          first boot ran, so this is the normal case. The layout is KEPT:
#          nothing is wiped and the images already on the mirror stay. Only
#          what the bundle changes is touched: USB LVs of another size are
#          recreated, the USB pool and the mirror are grown online if this
#          NVMe has room (lvextend / resize2fs on a mounted ext4 is safe).
#   wipe   No complete layout (blank disk, or a first boot that could not lay
#          out a smaller NVMe). Nothing is mounted, so the NVMe is wiped and
#          partitioned for this disk, as before.
# A mounted, in-use mirror is never torn down: that live teardown is what the
# factory reset had to move to early boot (an LV held open cannot be removed,
# parted jams the disk, only a reboot clears it) — here it could leave the
# unit half-provisioned, without data and without the bundle's settings.
#
# Usage:
#   provision-from-bundle.sh <bundle.citostore> --plan
#       Print the provisioning plan (path, layout) as JSON. Safe.
#   provision-from-bundle.sh <bundle.citostore> --provision --confirm
#       Apply the bundle (reuse path), or wipe + partition and apply (wipe path).

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

# Exported so the install/helper scripts we invoke (as separate processes)
# resolve this repo path rather than re-deriving from their own location.
export GATEWAY_HOME
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

# Pull the fixed values from the bundle config in a clean subshell. %q: the
# output is eval'd, and a value like "16G; reboot" must stay a value.
read_conf_vars() {
  (
    set +u
    # shellcheck source=/dev/null
    source "$BUNDLE_CONF"
    printf 'NVME_DEVICE=%q\n' "${NVME_DEVICE:-/dev/nvme0n1}"
    printf 'LVM_VG=%q\n' "${LVM_VG:-vg0}"
    printf 'MIRROR_LV=%q\n' "${MIRROR_LV:-mirror}"
    printf 'THINPOOL_LV=%q\n' "${THINPOOL_LV:-usbpool}"
    printf 'MIRROR_MOUNT=%q\n' "${MIRROR_MOUNT:-/srv/vision_mirror}"
    printf 'SYNC_MOUNT=%q\n' "${SYNC_MOUNT:-/mnt/vision_snap}"
    printf 'USB_LV_SIZE=%q\n' "${USB_LV_SIZE:-16G}"
    printf 'USB_LV_NAMES=%q\n' "${USB_LVS[*]:-usb_0}"
    printf 'BUNDLE_INGEST_DIR=%q\n' "${INGEST_DIR:-}"
  )
}
eval "$(read_conf_vars)"
read -r -a USB_LV_LIST <<< "$USB_LV_NAMES"
USB_LV_COUNT=${#USB_LV_LIST[@]}
for v in "$LVM_VG" "$MIRROR_LV" "$THINPOOL_LV" "${USB_LV_LIST[@]}"; do
  [[ "$v" =~ ^[A-Za-z0-9_.+-]+$ ]] || { echo "bundle has an invalid LVM name: '$v'" >&2; exit 1; }
done
USB_LV_SIZE=${USB_LV_SIZE^^}
if [[ ! "$USB_LV_SIZE" =~ ^[1-9][0-9]{0,6}[MG]$ ]]; then
  echo "bundle USB_LV_SIZE '$USB_LV_SIZE' is not a whole M/G size" >&2
  exit 1
fi
# In GiB, rounded up (a "512M" was read as 512 GiB).
if [[ "$USB_LV_SIZE" == *M ]]; then
  USB_LV_GIB=$(( (${USB_LV_SIZE%M} + 1023) / 1024 ))
  USB_LV_BYTES=$(( ${USB_LV_SIZE%M} * 1024 * 1024 ))
else
  USB_LV_GIB=${USB_LV_SIZE%G}
  USB_LV_BYTES=$(( USB_LV_GIB * 1024 * 1024 * 1024 ))
fi

if [[ ! -b "$NVME_DEVICE" ]]; then
  echo "nvme device not found: $NVME_DEVICE" >&2
  exit 1
fi

lv_bytes() { lvs --noheadings --units b --nosuffix -o "${2:-lv_size}" "$LVM_VG/$1" 2>/dev/null | tr -d ' ' | cut -d. -f1; }
gib() { echo $(( ${1:-0} / 1073741824 )); }

if lvs "$LVM_VG/$MIRROR_LV" >/dev/null 2>&1 && lvs "$LVM_VG/$THINPOOL_LV" >/dev/null 2>&1; then
  LAYOUT=reuse
else
  LAYOUT=wipe
fi

NVME_TOTAL_GIB=$(gib "$(blockdev --getsize64 "$NVME_DEVICE")")
PLAN_OK=true
PLAN_ERROR=""
RECREATE=()

if [[ "$LAYOUT" == wipe ]]; then
  # --- size adaptation: USB LVs fixed, mirror fills the rest of THIS NVMe ---
  usable=$((NVME_TOTAL_GIB - 1))                          # partition offset + LVM metadata
  USBPOOL_GIB=$((USB_LV_COUNT * USB_LV_GIB + USB_LV_GIB))  # LVs + one LV of snapshot headroom
  META_GIB=1
  reserve=$(( usable / 100 > 2 ? usable / 100 : 2 ))       # ~1% safety, min 2 GiB
  MIRROR_GIB=$((usable - USBPOOL_GIB - META_GIB - reserve))
  POOL_GROW_GIB=0
  MIRROR_GROW_GIB=0
  if ((MIRROR_GIB < MIN_MIRROR_GIB)); then
    PLAN_OK=false
    PLAN_ERROR="NVMe too small: computed mirror ${MIRROR_GIB}G < ${MIN_MIRROR_GIB}G minimum; reduce USB_LV_SIZE/USB_LVS in the bundle"
  fi
  # Never a running disk (see the header): a mirror of another name than the
  # bundle's, or anything else on this NVMe that is mounted, is in use.
  if mountpoint -q "$MIRROR_MOUNT" || lsblk -nro MOUNTPOINT "$NVME_DEVICE" 2>/dev/null | grep -q .; then
    PLAN_OK=false
    PLAN_ERROR="this NVMe is in use (mounted) but has no '$LVM_VG/$MIRROR_LV' + '$LVM_VG/$THINPOOL_LV' layout the bundle can reuse; re-laying out a running disk is not possible — use Factory Reset, then provision"
  fi
else
  # --- reuse: keep the layout, grow what this disk has room for ------------
  vg_free=$(vgs --noheadings --units b --nosuffix -o vg_free "$LVM_VG" 2>/dev/null | tr -d ' ' | cut -d. -f1)
  pool_bytes=$(lv_bytes "$THINPOOL_LV")
  META_GIB=$(gib "$(lv_bytes "$THINPOOL_LV" lv_metadata_size)")
  ((META_GIB > 0)) || META_GIB=1
  # All USB LVs must fit the pool (as the Resize check): grow it if needed.
  need=$((USB_LV_COUNT * USB_LV_BYTES))
  POOL_GROW_GIB=0
  if ((need > pool_bytes)); then
    POOL_GROW_GIB=$(( (need - pool_bytes + 1073741823) / 1073741824 ))
    if ((POOL_GROW_GIB * 1073741824 > vg_free)); then
      PLAN_OK=false
      PLAN_ERROR="the bundle's USB drives ($USB_LV_COUNT x $USB_LV_SIZE) do not fit this unit's USB pool ($(gib "$pool_bytes")G) and the NVMe has no free space to grow it; reduce USB_LV_SIZE in the bundle"
    fi
  fi
  USBPOOL_GIB=$(( $(gib "$pool_bytes") + POOL_GROW_GIB ))
  # A larger NVMe than the original: the mirror takes the free space (online).
  reserve=$(( NVME_TOTAL_GIB / 100 > 2 ? NVME_TOTAL_GIB / 100 : 2 ))
  MIRROR_GROW_GIB=$(( $(gib "$vg_free") - POOL_GROW_GIB - reserve ))
  ((MIRROR_GROW_GIB > 0)) || MIRROR_GROW_GIB=0
  MIRROR_GIB=$(( $(gib "$(lv_bytes "$MIRROR_LV")") + MIRROR_GROW_GIB ))
  # USB LVs of another size are recreated (empty); missing ones created.
  for lv in "${USB_LV_LIST[@]}"; do
    cur=$(lv_bytes "$lv")
    if [[ -n "$cur" && "$cur" != "$USB_LV_BYTES" ]]; then
      RECREATE+=("$lv")
    fi
  done
fi

emit_plan_json() {
  cat <<EOF
{
  "mode": "$LAYOUT",
  "images_kept": $([[ "$LAYOUT" == reuse ]] && echo true || echo false),
  "nvme_device": "$NVME_DEVICE",
  "nvme_total_gib": $NVME_TOTAL_GIB,
  "usb_lv_size": "$USB_LV_SIZE",
  "usb_lv_size_gib": $USB_LV_GIB,
  "usb_lv_count": $USB_LV_COUNT,
  "usb_lvs_recreated": ${#RECREATE[@]},
  "usbpool_gib": $USBPOOL_GIB,
  "meta_gib": $META_GIB,
  "mirror_gib": $MIRROR_GIB,
  "mirror_grow_gib": $MIRROR_GROW_GIB,
  "min_mirror_gib": $MIN_MIRROR_GIB,
  "ok": $PLAN_OK,
  "error": "$PLAN_ERROR"
}
EOF
}

if [[ "$MODE" == "plan" ]]; then
  emit_plan_json
  exit 0
fi

# ---------------- provisioning ----------------
if [[ "$PLAN_OK" != "true" ]]; then
  echo "$PLAN_ERROR; nothing changed" >&2
  exit 1
fi
if [[ "$CONFIRM" != "true" ]]; then
  echo "refusing to provision without --confirm" >&2
  exit 1
fi

# A failure part-way must not leave the AOI without its USB drive and the unit
# without its WebUI until someone power-cycles it.
on_exit() {
  local rc=$?
  rm -rf "$STAGE"
  if ((rc != 0)); then
    log "PROVISION FAILED (rc=$rc); restarting the services it stopped"
    systemctl start usb-gadget.service vision-webui.service smbd nmbd 2>/dev/null || true
    systemctl start vision-sync.timer vision-monitor.timer mirror-retention.timer 2>/dev/null || true
  fi
}
trap on_exit EXIT

log "PROVISION ($LAYOUT): applying bundle"
log "  layout: mirror=${MIRROR_GIB}G usbpool=${USBPOOL_GIB}G meta=${META_GIB}G usb_lv=${USB_LV_SIZE} x${USB_LV_COUNT}"

# 1) The bundle config, with THIS unit's layout sizes.
install -D -m 0644 "$BUNDLE_CONF" /etc/vision-gw.conf
set_conf_value MIRROR_SIZE "${MIRROR_GIB}G"
set_conf_value THINPOOL_SIZE "${USBPOOL_GIB}G"
set_conf_value THINPOOL_META_SIZE "${META_GIB}G"
set_conf_value USB_LV_SIZE "$USB_LV_SIZE"
ensure_gateway_home_in_conf

if [[ "$LAYOUT" == reuse ]]; then
  # 2) Only what uses the USB LVs stops; the mirror stays mounted.
  systemctl stop vision-sync.timer vision-sync-fast.timer vision-rotator.timer 2>/dev/null || true
  for ((i = 0; i < 2400; i++)); do
    case $(systemctl show -p ActiveState --value vision-sync.service 2>/dev/null) in
      activating | deactivating | reloading) sleep 1 ;;
      *) break ;;
    esac
  done
  systemctl stop usb-gadget.service 2>/dev/null || true
  bash "$GATEWAY_HOME/scripts/usb-gadget.sh" stop 2>/dev/null || true
  if ((POOL_GROW_GIB > 0)); then
    log "growing the USB pool by ${POOL_GROW_GIB}G"
    lvextend -L "+${POOL_GROW_GIB}G" "$LVM_VG/$THINPOOL_LV"
  fi
  for lv in "${RECREATE[@]}"; do
    log "recreating $lv at $USB_LV_SIZE"
    lvremove -y "$LVM_VG/$lv" || { echo "cannot remove $LVM_VG/$lv (in use?)" >&2; exit 1; }
  done
  # Creates the missing/removed USB LVs at the bundle size; never repartitions.
  bash "$GATEWAY_HOME/install/30_setup_nvme_lvm.sh"
  if ((MIRROR_GROW_GIB > 0)); then
    log "growing the mirror by ${MIRROR_GROW_GIB}G (online)"
    lvextend -r -L "+${MIRROR_GROW_GIB}G" "$LVM_VG/$MIRROR_LV"
  fi
else
  # 2) Nothing on this NVMe is mounted (checked in the plan): free any LVs a
  #    half-finished layout left active, then wipe + partition.
  log "tearing down the incomplete layout"
  systemctl stop vision-sync.timer vision-sync-fast.timer vision-monitor.timer \
    vision-rotator.timer mirror-retention.timer 2>/dev/null || true
  systemctl stop usb-gadget.service 2>/dev/null || true
  bash "$GATEWAY_HOME/scripts/usb-gadget.sh" stop 2>/dev/null || true
  vgchange -an "$LVM_VG" 2>/dev/null || true
  # Fallback: force-remove lingering mappings for this VG so the PV frees up.
  for d in $(dmsetup ls 2>/dev/null | awk -v vg="$LVM_VG" '$1 ~ "^"vg"-" {print $1}'); do
    dmsetup remove -f "$d" 2>/dev/null || true
  done
  bash "$GATEWAY_HOME/install/30_setup_nvme_lvm.sh" --wipe
fi

# 3) Ensure the mirror is mounted and .state exists.
mountpoint -q "$MIRROR_MOUNT" || mount "$MIRROR_MOUNT" || mount -a
mountpoint -q "$MIRROR_MOUNT" || { echo "mirror not mounted after the layout step" >&2; exit 1; }
STATE_DIR="$MIRROR_MOUNT/.state"
safe_mkdir "$STATE_DIR"

# 4) Config becomes the authoritative shadow copy.
cp /etc/vision-gw.conf "$STATE_DIR/vision-gw.conf"
cp /etc/vision-gw.conf "$STATE_DIR/vision-gw.conf.last-good"

# 5) Restore secrets + AOI settings from the bundle.
for f in webui.passwd webui.secret vision-nas.creds ftp.creds smb_unix.creds; do
  if [[ -f "$STAGE/state/$f" ]]; then
    install -m 0600 "$STAGE/state/$f" "$STATE_DIR/$f"
    log "restored $f"
  fi
done
# The recorded network intent (a static IP): exported, but never restored, so a
# replacement unit came up on DHCP instead of the failed unit's address.
if [[ -f "$STAGE/network/network.json" ]]; then
  install -m 0600 "$STAGE/network/network.json" "$STATE_DIR/network.json"
  log "restored network.json"
fi
if [[ -f "$STAGE/etc/vision-nas.creds" ]]; then
  install -m 0600 "$STAGE/etc/vision-nas.creds" /etc/vision-nas.creds
fi
if [[ -d "$STAGE/state/aoi_settings" ]]; then
  rm -rf "$STATE_DIR/aoi_settings"
  cp -a "$STAGE/state/aoi_settings" "$STATE_DIR/aoi_settings"
  log "restored aoi_settings"
  # ...and onto every USB drive (the gadget is stopped above). Drives kept by
  # the reuse path still held this unit's old folder: the next rotation would
  # have exported that over the bundle's settings. The persist manifest went
  # with the old content.
  for lv in "${USB_LV_LIST[@]}"; do
    st=$(usb_persist_write "/dev/$LVM_VG/$lv" "$STATE_DIR/aoi_settings" replace) || st="FAILED (mount)"
    log "$lv: aoi_settings $st"
  done
  rm -f "$STATE_DIR/usb_persist.manifest"
fi
# The Ethernet AOI's settings folder; the apply below (70_configure_ingest)
# hands it to the FTP user.
if [[ -d "$STAGE/ingest/aoi_settings" ]]; then
  INGEST_SETTINGS=$(INGEST_DIR=$BUNDLE_INGEST_DIR ingest_settings_dir)
  mkdir -p "$(dirname "$INGEST_SETTINGS")"
  rm -rf "$INGEST_SETTINGS"
  cp -a "$STAGE/ingest/aoi_settings" "$INGEST_SETTINGS"
  log "restored the Ethernet AOI's aoi_settings"
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

# The restored settings to disk before anything else: a power cut in the next
# ~30 s (ext4 delayed allocation) could leave them zero-length.
sync -f "$STATE_DIR" 2>/dev/null || sync

# 8) Bring the stack up — everything step 2 stopped (the monitor and retention
#    timers used to stay off until the next reboot).
systemctl start usb-gadget.service 2>/dev/null || true
systemctl start vision-sync.timer vision-monitor.timer mirror-retention.timer 2>/dev/null || true
systemctl restart vision-webui.service 2>/dev/null || true

log "PROVISION complete: unit provisioned from bundle ($LAYOUT)"
emit_plan_json

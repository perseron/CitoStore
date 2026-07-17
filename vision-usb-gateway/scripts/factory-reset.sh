#!/usr/bin/env bash
set -euo pipefail

# Factory reset: wipe the whole NVMe and rebuild it from nothing, exactly as if a
# blank drive had been fitted. Unlike "Wipe All Data" (which keeps config,
# network and every password), this clears ALL of it — the passwords, NAS creds,
# NetBIOS identity and captured data all live in .state on the NVMe, so wiping
# the NVMe removes them. The unit comes back at /setup with no password, like a
# fresh clone.
#
# It deliberately reuses the proven first-boot path (30_setup_nvme_lvm.sh --wipe)
# rather than reimplementing the teardown: that is the code that initialises an
# empty NVMe, and it is what runs on every clone's first boot. Everything after
# the wipe is handled by a normal reboot, so this does not try to re-establish
# mounts and services by hand.
#
# It does NOT reset the OS identity (hostname, machine-id, SSH host keys): those
# are on the eMMC under the read-only overlay and cannot be changed persistently
# from here. "A blank NVMe" does not imply a new OS anyway, and the hostname is
# derived from the CM5 serial, so it is stable hardware identity.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config

NVME_DEVICE="${NVME_DEVICE:-/dev/nvme0n1}"
LVM_VG="${LVM_VG:-vg0}"
MIRROR_MOUNT="${MIRROR_MOUNT:-/srv/vision_mirror}"
GATEWAY_HOME="${GATEWAY_HOME:?}"

CONFIRM=false
for arg in "$@"; do
  case "$arg" in
  --i-know-what-im-doing) CONFIRM=true ;;
  esac
done
if [[ "$CONFIRM" != "true" ]]; then
  echo "Refusing to run without --i-know-what-im-doing" >&2
  exit 1
fi

# Guard: only ever wipe the NVMe, never the boot device. If the root filesystem
# lives on NVME_DEVICE, something is misconfigured and a wipe would destroy the OS.
root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
if [[ -n "$root_src" && "$root_src" == "$NVME_DEVICE"* ]]; then
  echo "REFUSING: root filesystem is on $NVME_DEVICE — this is not the data drive" >&2
  exit 1
fi
if [[ ! -b "$NVME_DEVICE" ]]; then
  echo "REFUSING: $NVME_DEVICE is not a block device" >&2
  exit 1
fi

log "factory reset: releasing everything that holds the NVMe"

# Stop the data-plane services and the Samba passdb bind so the mirror can be
# unmounted. usb-gadget is the one that bites: it holds the active USB LV open, so
# without stopping it the VG will not deactivate and parted cannot repartition the
# NVMe ("Partition ... in use ... unable to inform the kernel"). At first boot the
# NVMe is empty and nothing holds it, which is why 30_setup's own teardown is
# enough there but not here.
for unit in vision-sync.timer vision-sync.service vision-rotator.service \
  vision-monitor.service mirror-retention.timer vision-shadow-config.service \
  usb-gadget.service smbd.service nmbd.service wsdd.service vsftpd.service; do
  systemctl stop "$unit" >/dev/null 2>&1 || true
done

# Tear the gadget's config down so it stops holding usb_2 (stopping the unit does
# not always unbind the UDC).
for g in /sys/kernel/config/usb_gadget/*; do
  [[ -d "$g" ]] || continue
  echo "" >"$g/UDC" 2>/dev/null || true
done

# Any USB export drive is on its own device, but its mount is under /srv; leave it
# alone (the wipe only touches the NVMe). Release the Samba passdb bind mount.
systemctl stop var-lib-samba.mount >/dev/null 2>&1 || true
umount /var/lib/samba >/dev/null 2>&1 || true

if mountpoint -q "$MIRROR_MOUNT"; then
  umount "$MIRROR_MOUNT" >/dev/null 2>&1 || {
    log "mirror busy; forcing"
    command -v fuser >/dev/null 2>&1 && fuser -km "$MIRROR_MOUNT" >/dev/null 2>&1 || true
    sleep 1
    umount "$MIRROR_MOUNT" >/dev/null 2>&1 || umount -l "$MIRROR_MOUNT" >/dev/null 2>&1 || true
  }
fi

# Explicitly tear down the LVM stack so the partition is genuinely free before
# 30_setup repartitions it. 30_setup does vgchange -an + wipefs, but on a live
# unit an LV that is still mapped keeps the PV busy; vgremove -f releases them all.
# Idempotent and best-effort: a fresh/half-wiped NVMe may have none of this.
log "factory reset: tearing down the existing LVM on $NVME_DEVICE"
vgchange -an "$LVM_VG" >/dev/null 2>&1 || true
vgremove -f "$LVM_VG" >/dev/null 2>&1 || true
for _p in "${NVME_DEVICE}"p*; do
  [[ -b "$_p" ]] && pvremove -ff -y "$_p" >/dev/null 2>&1 || true
done
udevadm settle >/dev/null 2>&1 || true

log "factory reset: wiping and re-initialising $NVME_DEVICE (proven first-boot path)"
"$GATEWAY_HOME/install/30_setup_nvme_lvm.sh" --wipe

# Mount the fresh mirror so the shadow config can be seeded onto it.
mountpoint -q "$MIRROR_MOUNT" || mount "$MIRROR_MOUNT" 2>/dev/null || mount -a || true
if ! mountpoint -q "$MIRROR_MOUNT"; then
  echo "factory reset: fresh mirror did not mount at $MIRROR_MOUNT" >&2
  exit 1
fi

STATE_DIR="$MIRROR_MOUNT/.state"
mkdir -p "$STATE_DIR"

# Seed the shadow config from the FACTORY default, not the config that is running
# now. The golden baked copy on the eMMC lower is the factory config (its NetBIOS
# name and tuned timings); the current /etc still holds the outgoing config in the
# overlay's RAM upper, so seeding from it would carry the old settings forward.
golden_conf=""
for cand in /media/root-ro/etc/vision-gw.conf /etc/vision-gw.conf; do
  if [[ -f "$cand" ]]; then
    golden_conf="$cand"
    break
  fi
done
if [[ -n "$golden_conf" ]]; then
  cp "$golden_conf" "$STATE_DIR/vision-gw.conf"
  cp "$golden_conf" "$STATE_DIR/vision-gw.conf.last-good"
  log "factory reset: shadow config seeded from $golden_conf"
else
  log "factory reset: no golden config found; boot will fall back to the example"
fi

log "factory reset complete — rebooting into a fresh unit"
sync
systemctl reboot

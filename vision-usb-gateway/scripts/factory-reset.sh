#!/usr/bin/env bash
set -euo pipefail

# Factory reset in two phases, because it cannot be done on a running system.
#
# Wiping the NVMe live is impossible and was proven so the hard way: parted on an
# in-use disk fails ("unable to inform the kernel ... in use") and jams it until a
# reboot; vgremove/dmsetup cannot release the mirror LV while it reads as open;
# and udev re-activates the VG faster than it can be torn down. The wipe only
# works at the point first boot does it — early in boot, before the mount, the
# gadget, sync or smbd have opened anything on the NVMe, so unmounting the mirror
# and deactivating the VG genuinely frees the disk.
#
# So:
#   --arm  (from the WebUI): drop a marker and reboot. Safe and trivial.
#   --boot (early-boot service): if the marker is present, wipe and rebuild the
#          NVMe from nothing, then let the rest of boot bring a fresh unit up.
#
# Every secret lives in .state on the NVMe (the SMB passdb, webui.passwd, FTP and
# NAS creds), so wiping it clears them: the unit comes back at /setup with no
# password, as if freshly imaged. The OS identity (hostname, machine-id, SSH keys)
# is on the eMMC and is left alone — a blank NVMe does not imply a new OS.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

NVME_DEVICE="${NVME_DEVICE:-/dev/nvme0n1}"
LVM_VG="${LVM_VG:-vg0}"
MIRROR_MOUNT="${MIRROR_MOUNT:-/srv/vision_mirror}"
BOOT_MOUNT=/boot/firmware
MARKER="$BOOT_MOUNT/factory-reset-pending"

MODE="${1:-}"

# Write to the FAT boot partition, which is persistent and readable at early boot.
# It is mounted read-only under the overlay, so flip it just long enough.
boot_write() {
  local was_ro=false
  if mountpoint -q "$BOOT_MOUNT" && findmnt -no OPTIONS "$BOOT_MOUNT" | tr ',' '\n' | grep -qx ro; then
    was_ro=true
    mount -o remount,rw "$BOOT_MOUNT"
  fi
  "$@"
  sync
  $was_ro && mount -o remount,ro "$BOOT_MOUNT" || true
}

case "$MODE" in
--arm)
  # Load config only to honour a custom GATEWAY_HOME etc; the wipe itself reads
  # config fresh at boot.
  load_config
  log "factory reset: arming — the unit will wipe its NVMe on the next boot"
  boot_write touch "$MARKER"
  log "factory reset: armed, rebooting"
  sync
  systemctl reboot
  ;;

--boot)
  [[ -f "$MARKER" ]] || exit 0

  # Remove the marker FIRST, so a wipe that fails cannot turn into a boot loop.
  # A degraded boot (mirror absent) is recoverable; a loop is not.
  boot_write rm -f "$MARKER"

  load_config
  NVME_DEVICE="${NVME_DEVICE:-/dev/nvme0n1}"
  LVM_VG="${LVM_VG:-vg0}"
  MIRROR_MOUNT="${MIRROR_MOUNT:-/srv/vision_mirror}"
  GATEWAY_HOME="${GATEWAY_HOME:?}"

  # Never wipe the boot device.
  root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
  if [[ -n "$root_src" && "$root_src" == "$NVME_DEVICE"* ]]; then
    log "factory reset: REFUSING — root is on $NVME_DEVICE"
    exit 1
  fi

  log "factory reset: marker present — wiping $NVME_DEVICE early in boot"

  # At this point only the mirror mount (and possibly the samba bind on top of it)
  # holds the NVMe — the gadget, sync, smbd and retention are all ordered after
  # this service and have not opened anything yet. That is the whole reason this
  # works here and not on a running system.
  umount /var/lib/samba >/dev/null 2>&1 || true
  if mountpoint -q "$MIRROR_MOUNT"; then
    umount "$MIRROR_MOUNT" >/dev/null 2>&1 || umount -l "$MIRROR_MOUNT" >/dev/null 2>&1 || true
  fi
  vgchange -an "$LVM_VG" >/dev/null 2>&1 || true
  udevadm settle >/dev/null 2>&1 || true

  # The proven first-boot initialiser. A full wipe (parted + fresh PV + VG + LVs)
  # works now that the disk is free. /etc still holds the golden baked config at
  # this point in boot (vision-gw-config, which copies the shadow over it, is
  # ordered after us), so the LV sizes are the factory ones.
  "$GATEWAY_HOME/install/30_setup_nvme_lvm.sh" --wipe

  # Mount the fresh mirror just long enough to seed .state onto it. This is a
  # bare `mount`, so systemd's own srv-vision_mirror.mount unit does not consider
  # itself active — which is exactly why we do NOT try to continue this boot:
  # var-lib-samba.mount (Requires=srv-vision_mirror.mount) and the config applier
  # would not start, and smbd would stay down. A clean reboot mounts everything
  # through systemd and brings the unit up properly.
  mountpoint -q "$MIRROR_MOUNT" || mount "$MIRROR_MOUNT" 2>/dev/null || mount -a || true
  if ! mountpoint -q "$MIRROR_MOUNT"; then
    log "factory reset: fresh mirror did not mount — boot will continue degraded"
    exit 1
  fi

  # Seed the shadow config from the factory (golden) /etc so boot 2 has something
  # to apply; without it, restore_shadow_conf falls back to the packaged example
  # and loses the tuned identity.
  #
  # Deliberately do NOT create .state/samba here. 50_configure_samba's
  # setup_samba_persist creates it AND seeds the package's tdb skeleton
  # (secrets.tdb etc.) into it only when it is empty, then binds it. Pre-creating
  # an empty .state/samba makes var-lib-samba.mount bind it first, after which
  # setup_samba_persist sees "already mounted" and skips the seed — leaving smbd
  # unable to open secrets.tdb. Boot 2 is a clean boot, so leaving .state as a
  # fresh clone would makes the samba setup identical to a first-boot clone, which
  # is the proven path.
  STATE_DIR="$MIRROR_MOUNT/.state"
  mkdir -p "$STATE_DIR"
  if [[ -f /etc/vision-gw.conf ]]; then
    cp /etc/vision-gw.conf "$STATE_DIR/vision-gw.conf"
    cp /etc/vision-gw.conf "$STATE_DIR/vision-gw.conf.last-good"
    log "factory reset: shadow config seeded from /etc (factory)"
  fi

  # The marker is already gone, so this second boot is an ordinary one: the mirror
  # LV now exists, systemd mounts it, the samba bind and config applier run, and
  # smbd comes up. Rebooting is far cleaner than fighting systemd's mount state
  # after a bare mount mid-boot.
  sync
  umount "$MIRROR_MOUNT" >/dev/null 2>&1 || true
  log "factory reset: NVMe rebuilt — rebooting into the fresh unit"
  systemctl reboot
  ;;

*)
  echo "usage: $0 {--arm|--boot}" >&2
  exit 1
  ;;
esac

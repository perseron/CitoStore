#!/usr/bin/env bash
set -euo pipefail

# Mount / unmount a plugged-in USB drive for manual export of mirror data.
#
# Called by udev (via citostore-usb-mount@.service) when a USB block device with
# a filesystem appears or goes away. One drive at a time, at a fixed path, so the
# SMB share and the WebUI always point somewhere predictable.
#
# SAFETY: this must never touch the gadget's backing LVs (usb_0/1/2), the NVMe or
# the eMMC. Mounting a live gadget-backed LV corrupts the FAT under the AOI —
# the host and the Pi would both be writing a filesystem neither one is tracking.
# The udev rule already narrows to ID_BUS=usb (the LVs are device-mapper, the
# NVMe is nvme, the eMMC is mmc, and the Pi is the *peripheral* on the gadget so
# it never sees it as a block device at all), but the cost of a mistake here is
# silent data loss during production, so re-check rather than trust the caller.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config

USB_EXPORT_ENABLED=${USB_EXPORT_ENABLED:-true}
USB_EXPORT_MOUNT=${USB_EXPORT_MOUNT:-/srv/usb_backup}
# Write-through would let an operator unplug without a "safely remove" step, but
# measured on a real stick it costs 3.4x: 7 MB/s vs 24 MB/s, i.e. 4.6 hours
# instead of 1.4 for a 117 GB drive. Not worth it — eject deliberately instead.
USB_EXPORT_SYNC=${USB_EXPORT_SYNC:-false}
SMB_USER=${SMB_USER:-smbuser}

action="${1:-}"
devname="${2:-}"

[[ "$USB_EXPORT_ENABLED" == "true" ]] || { log "usb-export disabled"; exit 0; }
[[ -n "$devname" ]] || { log "usb-export: no device given"; exit 1; }
dev="/dev/$devname"

# --- refuse anything that is not a genuine hot-plugged USB disk ---------------
guard() {
  local d="$1"

  # The gadget's LVs live in our VG; the mirror and usbpool are on the NVMe.
  case "$d" in
  /dev/dm-* | /dev/mapper/* | /dev/nvme* | /dev/mmcblk*)
    log "usb-export: REFUSING $d — not a hot-plugged USB disk"
    return 1
    ;;
  esac

  # udev's own verdict, read back from the device rather than trusted from argv.
  local bus
  bus=$(udevadm info --query=property --name="$d" 2>/dev/null |
    sed -n 's/^ID_BUS=//p' | head -1)
  if [[ "$bus" != "usb" ]]; then
    log "usb-export: REFUSING $d — ID_BUS='$bus', expected 'usb'"
    return 1
  fi

  # Belt and braces: an LV that somehow reached here would be holder-linked to a
  # dm device, and the gadget's backing store must never be mounted locally.
  if lsblk -no NAME "$d" 2>/dev/null | grep -qE 'usb_[0-9]+'; then
    log "usb-export: REFUSING $d — resolves to a gadget-backed LV"
    return 1
  fi
  return 0
}

mount_opts_for() {
  local fstype="$1" opts="nosuid,nodev,noexec"
  [[ "$USB_EXPORT_SYNC" == "true" ]] && opts="$opts,sync"
  case "$fstype" in
  vfat | exfat | ntfs | ntfs3)
    # These have no Unix ownership; map the whole tree to the SMB user so the
    # share is writable and the WebUI can read it.
    local uid gid
    uid=$(id -u "$SMB_USER" 2>/dev/null || echo 0)
    gid=$(id -g "$SMB_USER" 2>/dev/null || echo 0)
    opts="$opts,uid=$uid,gid=$gid,umask=0002"
    ;;
  esac
  printf '%s' "$opts"
}

case "$action" in
add)
  guard "$dev" || exit 0

  if mountpoint -q "$USB_EXPORT_MOUNT"; then
    log "usb-export: $USB_EXPORT_MOUNT already in use; ignoring $dev"
    exit 0
  fi

  fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
  if [[ -z "$fstype" ]]; then
    log "usb-export: $dev has no filesystem; ignoring"
    exit 0
  fi

  # blkid says "ntfs", and `mount -t ntfs` resolves to the ntfs-3g FUSE helper —
  # this kernel ships the in-tree ntfs3 driver, which is far faster. exfat is
  # in-tree too, so neither needs a FUSE package.
  if [[ "$fstype" == "ntfs" ]] && /sbin/modinfo -F filename ntfs3 >/dev/null 2>&1; then
    log "usb-export: using the in-kernel ntfs3 driver instead of ntfs-3g"
    fstype=ntfs3
  fi

  mkdir -p "$USB_EXPORT_MOUNT"
  opts=$(mount_opts_for "$fstype")
  if mount -t "$fstype" -o "$opts" "$dev" "$USB_EXPORT_MOUNT" 2>/dev/null; then
    log "usb-export: mounted $dev ($fstype) at $USB_EXPORT_MOUNT [$opts]"
  elif mount -o "$opts" "$dev" "$USB_EXPORT_MOUNT" 2>/dev/null; then
    # exFAT/NTFS go through FUSE helpers that pick their own type name.
    log "usb-export: mounted $dev (auto, $fstype) at $USB_EXPORT_MOUNT"
  else
    log "usb-export: FAILED to mount $dev ($fstype) — is the driver present?"
    exit 0
  fi
  printf '%s' "$dev" >/run/citostore-usb-export.dev 2>/dev/null || true
  ;;

remove)
  if mountpoint -q "$USB_EXPORT_MOUNT"; then
    sync
    if umount "$USB_EXPORT_MOUNT" 2>/dev/null; then
      log "usb-export: unmounted $USB_EXPORT_MOUNT"
    else
      umount -l "$USB_EXPORT_MOUNT" 2>/dev/null &&
        log "usb-export: lazy-unmounted $USB_EXPORT_MOUNT (was busy)"
    fi
  fi
  rm -f /run/citostore-usb-export.dev
  ;;

*)
  echo "usage: $0 {add|remove} <devname>" >&2
  exit 1
  ;;
esac

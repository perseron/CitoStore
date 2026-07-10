#!/usr/bin/env bash
set -uo pipefail

# Grow the eMMC root filesystem to fill its partition. Runs on every boot and is
# idempotent (a no-op once the fs already fills the partition). This is the
# reliable half of the shrunk-image auto-expand: firstboot enlarges the PARTITION
# with parted, and on the next boot the kernel sees the enlarged partition freshly
# so resize2fs can grow the FS. Works under the read-only overlay by briefly
# remounting the eMMC lower read-write. Doing resize2fs in firstboot's own boot
# proved unreliable (the just-grown partition was not visible to the kernel yet).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"
require_root

# The eMMC root is the overlay's read-only lower (/media/root-ro) under overlay,
# or / directly when the overlay is off.
if findmnt -no FSTYPE / 2>/dev/null | grep -q overlay; then
  mnt=/media/root-ro
else
  mnt=/
fi
dev=$(findmnt -no SOURCE "$mnt" 2>/dev/null)
[[ "$dev" == /dev/* ]] || exit 0

# Best-effort: make sure the partition itself fills the disk (idempotent).
disk=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
pnum=$(printf '%s' "$dev" | grep -oE '[0-9]+$')
if [[ -n "$disk" && -n "$pnum" ]] && command -v parted >/dev/null 2>&1; then
  parted -s "/dev/$disk" resizepart "$pnum" 100% >/dev/null 2>&1 || true
  partx -u "/dev/$disk" >/dev/null 2>&1 || partprobe "/dev/$disk" >/dev/null 2>&1 || true
fi

# Grow the fs only if it is meaningfully (>64 MiB) smaller than its partition.
part_bytes=$(( $(blockdev --getsz "$dev" 2>/dev/null || echo 0) * 512 ))
bc=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F: '/Block count/{gsub(/[^0-9]/,"",$2);print $2}')
bs=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F: '/Block size/{gsub(/[^0-9]/,"",$2);print $2}')
fs_bytes=$(( ${bc:-0} * ${bs:-0} ))
if (( part_bytes > 0 && fs_bytes > 0 && part_bytes - fs_bytes > 67108864 )); then
  log "growing root fs on $dev ($(( fs_bytes/1024/1024 ))M -> $(( part_bytes/1024/1024 ))M)"
  ro=false
  if findmnt -no OPTIONS "$mnt" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
    mount -o remount,rw "$mnt" && ro=true
  fi
  resize2fs "$dev" >/dev/null 2>&1 || log "resize2fs failed"
  if $ro; then mount -o remount,ro "$mnt" || true; fi
fi

#!/usr/bin/env bash
set -euo pipefail

# The boot fsck tells bookkeeping from damage (common.sh
# fsck_fat_only_bookkeeping): the FSInfo free-cluster count and the dirty flag
# are off on the drive the host had whenever the power went (seen live on every
# reboot: "fsck.fat repaired the FAT"), real repairs still warn. Real fsck.fat
# on crafted FAT32 images, in a container:
#   docker run --rm -v "$PWD:/gw:ro" debian:bookworm bash /gw/tests/functional/test_fsck_bookkeeping.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ -f /.dockerenv ]] || { echo "refusing to run outside a container" >&2; exit 1; }
command -v fsck.fat >/dev/null && command -v mcopy >/dev/null && command -v python3 >/dev/null || {
  apt-get update -qq >/dev/null && apt-get install -y -qq dosfstools mtools python3 >/dev/null
}
# shellcheck source=/dev/null
source <(tr -d '\r' < "$GW/scripts/common.sh")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
IMG=$TMP/f.img
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

fresh() {
  rm -f "$IMG"; truncate -s 300M "$IMG"
  mkfs.vfat -F 32 -n AOI "$IMG" >/dev/null
  echo img > "$TMP/a.jpg"; mcopy -i "$IMG" "$TMP/a.jpg" ::/a.jpg
}
# Edits of the boot sector's own structures (little-endian, FAT32 layout).
poke() { python3 - "$IMG" "$1" <<'PY'
import struct, sys
f = open(sys.argv[1], "r+b")
def u16(o): f.seek(o); return struct.unpack("<H", f.read(2))[0]
def rd(o): f.seek(o); return struct.unpack("<I", f.read(4))[0]
def wr(o, v): f.seek(o); f.write(struct.pack("<I", v))
fsinfo = u16(48) * 512 + 488          # FSInfo free-cluster count
fat1 = u16(14) * 512                  # first FAT
what = sys.argv[2]
if what == "free":   wr(fsinfo, rd(fsinfo) + 2)
if what == "uninit": wr(fsinfo, 0xFFFFFFFF)
if what == "dirty":  wr(fat1 + 4, rd(fat1 + 4) & ~0x08000000)   # clean-shutdown bit off
if what == "lost":   wr(fat1 + 4 * 100, 0x0FFFFFFF)            # a cluster in use by nothing
if what == "ntdirty":                                          # Windows' dirty flag, primary only
    f.seek(65); f.write(bytes([1]))
if what == "volid":                                            # another boot-sector byte than 65
    f.seek(67); b = f.read(1)[0]; f.seek(67); f.write(bytes([b ^ 0xFF]))
PY
}
classify() {  # fsck rc + verdict
  local out rc=0
  out=$(fsck.fat -a "$IMG" 2>&1) || rc=$?
  if ((rc == 1)) && fsck_fat_only_bookkeeping "$out"; then echo "rc$rc:bookkeeping"; else echo "rc$rc:repair"; fi
}

echo "=== bookkeeping only: no warning at boot ==="
fresh; poke free;                        check "free-cluster count off (Windows' lazy FSInfo)" "$(classify)" "rc1:bookkeeping"
fresh; poke uninit;                      check "free-cluster count uninitialized" "$(classify)" "rc1:bookkeeping"
fresh; poke dirty;                       check "dirty flag (host had it mounted), with the FAT copy" "$(classify)" "rc1:bookkeeping"
fresh; poke dirty; poke free;            check "both" "$(classify)" "rc1:bookkeeping"
fresh; poke ntdirty; poke dirty; poke free
check "Windows' dirty flag in the boot sector too (seen live: write, then reboot at once)" "$(classify)" "rc1:bookkeeping"
check "  ... and fsck cleared it: clean on the next boot" "$(classify)" "rc0:repair"
fresh;                                   check "clean: nothing to correct" "$(classify)" "rc0:repair"

echo "=== real repairs still warn ==="
fresh; poke lost;                        check "a lost cluster reclaimed" "$(classify)" "rc1:repair"
fresh; poke lost; poke dirty; poke free; check "  ... also next to the bookkeeping" "$(classify)" "rc1:repair"
fresh; poke volid; poke ntdirty; poke dirty
check "a boot-sector byte other than 65 differing from its backup" "$(classify)" "rc1:repair"
check "an unknown line counts as a repair" \
  "$(fsck_fat_only_bookkeeping $'fsck.fat 4.2\n/a.jpg\n  File size is 9 bytes, cluster chain length is 0.\n  Truncating file to 0 bytes.' && echo bookkeeping || echo repair)" repair

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"

#!/usr/bin/env bash
set -euo pipefail

# Rotation and the drives' export/reformat (vision-rotator.sh, offline-maint.sh):
# - one at a time (usb_lock): "Rotate USB Now" right after an automatic
#   rotation let the first one's offline-maint format the drive the second had
#   just given the AOI;
# - an export/reformat cut short is finished before the drive is used again
#   (usb_maint_marker) — it used to come back to the AOI with its old images;
# - a drive with no FAT is formatted before the switch, never exported as is;
# - nothing is formatted without the mirror (its images would be lost).
# LVM, the gadget, mount/mkfs/blkid and the export are stubbed; the scripts,
# the lock (flock) and the markers are real. Root, in a throwaway container:
#   docker run --rm -v "$PWD:/gw:ro" debian:bookworm bash /gw/tests/functional/test_usb_rotation.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 && -f /.dockerenv ]] || { echo "run as root in a container (writes /run)" >&2; exit 1; }
command -v flock >/dev/null || { echo "needs util-linux (flock)" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" /run/vision-usb-active /run/vision-rotate.state /run/vision-usb.lock' EXIT
FAKE=$TMP/gw; B=$TMP/bin; M=$TMP/mirror
mkdir -p "$FAKE/scripts" "$B" "$M/.state"
for f in common.sh vision-rotator.sh offline-maint.sh; do tr -d '\r' < "$GW/scripts/$f" > "$FAKE/scripts/$f"; done
# The gadget switch: the next LV in the ring becomes the active one.
cat > "$FAKE/scripts/usb-gadget.sh" <<EOF
#!/bin/bash
cur=\$(cat /run/vision-usb-active); n=\${cur##*_}; nxt="/dev/vg0/usb_\$(( (n + 1) % 3 ))"
echo "\$nxt" > /run/vision-usb-active; echo "switch \$cur -> \$nxt" >> $TMP/calls
EOF
cat > /etc/vision-gw.conf <<EOF
LVM_VG=vg0
USB_LVS=(usb_0 usb_1 usb_2)
MIRROR_MOUNT=$M
USB_PERSIST_DIR=none
USB_LABEL=AOI
SWITCH_WINDOW_START=00:00
SWITCH_WINDOW_END=23:59
EOF
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$B/$1"; chmod +x "$B/$1"; }
stub systemctl 'echo "systemctl $*" >> '"$TMP"'/calls'
stub python3 'echo "export $*" >> '"$TMP"'/calls; exit $(cat '"$TMP"'/export_rc 2>/dev/null || echo 0)'
stub blkid 'd=${@: -1}; [[ -f '"$TMP"'/nofat_${d##*/} ]] || echo vfat'
stub mountpoint '[[ ! -f '"$TMP"'/no_mirror ]]'
stub mkfs.vfat 'echo "mkfs ${@: -1}" >> '"$TMP"'/calls'
stub blkdiscard 'echo "discard $1" >> '"$TMP"'/calls'
for c in fsck.fat sfdisk mount umount partx kpartx; do stub "$c" 'exit 0'; done
export PATH="$B:$PATH" GATEWAY_HOME=$FAKE

marker() { echo "$M/.state/usb-maint-pending.$1"; }
reset() {
  : > "$TMP/calls"; rm -f "$TMP"/nofat_* "$TMP/export_rc" "$TMP/no_mirror" "$M"/.state/usb-maint-pending.*
  echo /dev/vg0/usb_0 > /run/vision-usb-active; echo "state=panic" > /run/vision-rotate.state
}
rotate() { bash "$FAKE/scripts/vision-rotator.sh" >"$TMP/out" 2>&1 && echo rc=0 || echo "rc=$?"; }
calls() { tr '\n' ';' < "$TMP/calls"; }

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

echo "=== a normal rotation ==="
reset
check "switched, old drive marked, its export started" "$(rotate):$(calls)" \
  "rc=0:switch /dev/vg0/usb_0 -> /dev/vg0/usb_1;systemctl start offline-maint@usb_0.service;"
check "  ... marked before its export" "$(test -e "$(marker usb_0)" && echo marked)" marked
check "  ... state back to ok" "$(cat /run/vision-rotate.state)" "state=ok"

echo "=== the export of the old drive (offline-maint@usb_0) ==="
: > "$TMP/calls"
bash "$FAKE/scripts/offline-maint.sh" usb_0 >"$TMP/out" 2>&1
check "exported, then reformatted" "$(calls)" "export -m vision_sync.sync --config /etc/vision-gw.conf --dev /dev/vg0/usb_0 --offline;discard /dev/vg0/usb_0;mkfs /dev/vg0/usb_0;"
check "  ... marker cleared" "$(test -e "$(marker usb_0)" && echo marked || echo clear)" clear
: > "$TMP/calls"
bash "$FAKE/scripts/offline-maint.sh" usb_0 >"$TMP/out" 2>&1
check "run again (queued after the rotator did it): nothing pending, nothing formatted" "$(calls)" ""

echo "=== the next drive's export was cut short ==="
reset; touch "$(marker usb_1)"
check "finished first, then switched" "$(rotate):$(calls)" \
  "rc=0:export -m vision_sync.sync --config /etc/vision-gw.conf --dev /dev/vg0/usb_1 --offline;discard /dev/vg0/usb_1;mkfs /dev/vg0/usb_1;switch /dev/vg0/usb_0 -> /dev/vg0/usb_1;systemctl start offline-maint@usb_0.service;"
reset; touch "$(marker usb_1)"; echo 1 > "$TMP/export_rc"
check "...and if that export fails: no switch, nothing formatted, the AOI keeps its drive" "$(rotate):$(calls):$(cat /run/vision-usb-active)" \
  "rc=1:export -m vision_sync.sync --config /etc/vision-gw.conf --dev /dev/vg0/usb_1 --offline;:/dev/vg0/usb_0"

echo "=== the next drive has no FAT ==="
reset; touch "$TMP/nofat_usb_1"
check "formatted (nothing exported), then switched" "$(rotate):$(calls)" \
  "rc=0:discard /dev/vg0/usb_1;mkfs /dev/vg0/usb_1;switch /dev/vg0/usb_0 -> /dev/vg0/usb_1;systemctl start offline-maint@usb_0.service;"

echo "=== no mirror: nothing is formatted ==="
reset; touch "$(marker usb_1)" "$TMP/no_mirror"
check "a pending drive is kept as it is, no switch" "$(rotate):$(calls)" "rc=1:"

echo "=== one at a time ==="
reset
( exec 8>>/run/vision-usb.lock; flock 8; sleep 2 ) &
sleep 0.3
s=$(date +%s); r=$(rotate); took=$(( $(date +%s) - s ))
wait
check "waits for the export/format in progress, then rotates" "$r:$(( took >= 1 ))" "rc=0:1"
reset; echo /dev/vg0/usb_1 > /run/vision-usb-active
touch "$(marker usb_1)"
: > "$TMP/calls"
bash "$FAKE/scripts/offline-maint.sh" usb_1 >"$TMP/out" 2>&1 || true
check "offline-maint never formats the drive the AOI has now" "$(calls)" ""

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"

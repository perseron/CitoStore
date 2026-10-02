#!/usr/bin/env bash
set -euo pipefail

# The AOI's settings folder (aoi_settings) on real FAT32 drives (loop devices):
# usb_persist_write ensure/replace, the rotator's persist check reading the
# sync's manifest format, and the "empty folder must not erase the NVMe copy"
# guard in offline-maint. Needs a privileged container (loop + vfat mounts):
#   docker run --rm --privileged -v "$PWD:/src:ro" debian:bookworm bash -c \
#     'apt-get update -qq && apt-get install -y -qq dosfstools python3 fdisk >/dev/null; \
#      cp -r /src /gw && bash /gw/tests/functional/test_aoi_settings.sh'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 ]] || { echo "run as root in a container" >&2; exit 1; }
[[ -f /.dockerenv ]] || { echo "refusing to run outside a container" >&2; exit 1; }

TMP=$(mktemp -d)
cleanup() {
  umount "$TMP"/m* 2>/dev/null || true
  # By backing file: new_drive runs in $(...), so a list kept in a variable
  # never reached this trap and every run leaked its loop devices.
  local img l
  for img in "$TMP"/*.img; do
    for l in $(losetup -j "$img" 2>/dev/null | cut -d: -f1); do losetup -d "$l" 2>/dev/null || true; done
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

tr -d '\r' < "$GW/scripts/common.sh" > "$TMP/common.sh"
# shellcheck source=/dev/null
source "$TMP/common.sh"
log() { echo "[log] $*" >> "$TMP/log"; }

new_drive() {  # a fresh FAT32 "USB LV" (as 30_setup makes it: no folder)
  local img="$TMP/$1.img" l
  truncate -s 64M "$img"
  mkfs.vfat -F 32 -n VISIONUSB "$img" >/dev/null
  l=$(losetup -f --show "$img")
  echo "$l"
}
look() {  # <dev> <cmd...> run with the drive mounted read-only at $TMP/m
  mkdir -p "$TMP/m"
  mount -t vfat -o ro "$1" "$TMP/m"
  shift
  "$@" || true
  umount "$TMP/m"
}
tree() { (cd "$TMP/m/aoi_settings" 2>/dev/null && find . -type f | sort | tr '\n' ' ') || echo "NO-FOLDER"; }

BACK=$TMP/backing
mkdir -p "$BACK/recipes"
echo "speed=5" > "$BACK/aoi.ini"; touch -d "2026-09-01 10:00:00" "$BACK/aoi.ini"
echo "r1" > "$BACK/recipes/board-a.rcp"

echo "=== a drive fresh from install has no folder: it is created from the NVMe copy ==="
d1=$(new_drive usb_0)
check "before: no folder (what 30_setup used to leave)" "$(look "$d1" tree)" "NO-FOLDER"
check "ensure -> restored" "$(usb_persist_write "$d1" "$BACK" ensure)" restored
check "folder holds the AOI's settings" "$(look "$d1" tree)" "./aoi.ini ./recipes/board-a.rcp "
check "  ... content intact" "$(look "$d1" cat "$TMP/m/aoi_settings/aoi.ini")" "speed=5"
check "  ... mtime kept (the persist manifest hashes it)" "$(look "$d1" date -r "$TMP/m/aoi_settings/aoi.ini" '+%F %H:%M')" "2026-09-01 10:00"

echo "=== a drive that has the folder is left alone ==="
mkdir -p "$TMP/m" && mount -t vfat "$d1" "$TMP/m" && echo "aoi-wrote-this" > "$TMP/m/aoi_settings/new.ini" && umount "$TMP/m"
check "ensure -> ok" "$(usb_persist_write "$d1" "$BACK" ensure)" ok
check "the AOI's own newer file untouched" "$(look "$d1" cat "$TMP/m/aoi_settings/new.ini")" "aoi-wrote-this"

echo "=== no NVMe copy yet (blank unit): an empty folder ==="
d2=$(new_drive usb_1)
check "ensure -> created" "$(usb_persist_write "$d2" "$TMP/no-backing" ensure)" created
check "folder exists, empty" "$(look "$d2" tree)" ""

echo "=== replace (provision): the bundle's settings, exactly ==="
d3=$(new_drive usb_2)
usb_persist_write "$d3" "$BACK" ensure >/dev/null
mkdir -p "$TMP/bundle"; echo "speed=9" > "$TMP/bundle/aoi.ini"
check "replace -> replaced" "$(usb_persist_write "$d3" "$TMP/bundle" replace)" replaced
check "old files gone, bundle's content only" "$(look "$d3" tree)" "./aoi.ini "
check "  ... bundle's value" "$(look "$d3" cat "$TMP/m/aoi_settings/aoi.ini")" "speed=9"

echo "=== a drive that cannot be mounted is reported, not skipped silently ==="
rc=0; usb_persist_write /dev/null "$BACK" ensure >/dev/null || rc=$?
check "ensure returns 1" "$rc" 1

echo "=== rotator reads the sync's manifest format (the check never matched) ==="
# The rotator's own persist_manifest_for, taken verbatim from the script.
eval "$(tr -d '\r' < "$GW/scripts/vision-rotator.sh" | sed -n '/^persist_manifest_for() {$/,/^}$/p')"
PYTHONPATH="$GW/src" python3 - "$d1" "$TMP/manifest" <<'PY'
import subprocess, sys
from pathlib import Path
from vision_sync.fsops import compute_manifest
from vision_sync.sync import write_manifest_state
dev, manifest = sys.argv[1], Path(sys.argv[2])
m = Path("/tmp/aoi-py-mnt"); m.mkdir(exist_ok=True)
subprocess.run(["mount", "-t", "vfat", "-o", "ro", dev, str(m)], check=True)
try:
    write_manifest_state(manifest, compute_manifest(m / "aoi_settings"), 0, "active")
finally:
    subprocess.run(["umount", str(m)], check=True)
PY
expected=$(sed -n 's/^digest=//p' "$TMP/manifest" | head -1)
actual=$(look "$d1" persist_manifest_for "$TMP/m/aoi_settings")
check "manifest written by the sync is digest=/count=/mode=" "$(head -1 "$TMP/manifest" | cut -c1-7)" "digest="
check "rotator's digest of the same drive == the sync's" "$actual" "$expected"
check "rotator script parses digest= (not the whole file)" \
  "$(tr -d '\r' < "$GW/scripts/vision-rotator.sh" | grep -c "sed -n 's/^digest=//p' \"\$USB_PERSIST_MANIFEST\"")" 1

echo "=== an empty folder never erases the NVMe copy ==="
out=$(PYTHONPATH="$GW/src" python3 - "$TMP" <<'PY'
import sys, types
from pathlib import Path
import vision_sync.sync as s
tmp = Path(sys.argv[1])
root = tmp / "active"; (root / "aoi_settings").mkdir(parents=True)
backing = tmp / "py-backing"; backing.mkdir(); (backing / "aoi.ini").write_text("speed=5")
state = tmp / "state"; state.mkdir()
cfg = types.SimpleNamespace(usb_persist_dir="aoi_settings", usb_persist_backing=backing, state_dir=state,
                            lvm_vg="vg0", usb_lvs=["usb_0", "usb_1"])
s.persist_enabled = lambda c: True
s.mount_rw = lambda *a, **k: None
s.umount = lambda *a, **k: None
s.maybe_sync_persist(cfg, root, "/dev/vg0/usb_0")
print("guard:", "kept" if (backing / "aoi.ini").exists() else "ERASED")
(root / "aoi_settings" / "aoi.ini").write_text("speed=77")
s.maybe_sync_persist(cfg, root, "/dev/vg0/usb_0")
print("real change:", (backing / "aoi.ini").read_text())
PY
)
check "sync: empty folder on the active drive keeps the NVMe copy" "$(grep -c '^guard: kept$' <<<"$out")" 1
check "sync: a real change still reaches the NVMe copy" "$(grep -c '^real change: speed=77$' <<<"$out")" 1

echo "=== offline-maint skips exporting an empty folder over the copy ==="
check "guard present in offline-maint" \
  "$(tr -d '\r' < "$GW/scripts/offline-maint.sh" | grep -c 'persist export skipped')" 1
echo
if ((fail)); then echo "FAILED"; cat "$TMP/log" 2>/dev/null; exit 1; fi
echo "ALL PASSED"

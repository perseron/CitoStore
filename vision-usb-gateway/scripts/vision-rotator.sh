#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config "${CONF_FILE:-}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_FILE=/run/vision-rotate.state
ACTIVE_FILE=/run/vision-usb-active

: "${SWITCH_WINDOW_START:=00:00}"
: "${SWITCH_WINDOW_END:=23:59}"
: "${MIRROR_MOUNT:=/srv/vision_mirror}"
: "${USB_PERSIST_DIR:=aoi_settings}"
: "${USB_PERSIST_BACKING:=$MIRROR_MOUNT/.state/$USB_PERSIST_DIR}"
: "${USB_PERSIST_MANIFEST:=$MIRROR_MOUNT/.state/usb_persist.manifest}"

PERSIST_MNT="/mnt/vision_persist_next"

within_window() {
  local now start end
  # 10# forces base-10: [[ -ge ]] evaluates operands arithmetically, and a
  # leading zero makes bash read HHMM as octal — "0800".."0959" (digits 8/9)
  # are then INVALID numbers, the comparison errors, and set -e kills the
  # whole rotator, blocking every normal rotation for those two hours daily.
  # Caught live: "[[: 0109: value too great for base".
  now=$((10#$(date +%H%M)))
  start=$((10#${SWITCH_WINDOW_START/:/}))
  end=$((10#${SWITCH_WINDOW_END/:/}))
  if [[ $start -le $end ]]; then
    [[ $now -ge $start && $now -le $end ]]
  else
    [[ $now -ge $start || $now -le $end ]]
  fi
}

persist_enabled() {
  [[ -n "${USB_PERSIST_DIR:-}" && "${USB_PERSIST_DIR}" != "none" ]]
}

next_lv() {
  local current="$1"
  local name
  name=$(basename "$current")
  local idx=-1
  for i in "${!USB_LVS[@]}"; do
    if [[ "${USB_LVS[$i]}" == "$name" ]]; then
      idx=$i
      break
    fi
  done
  if [[ $idx -lt 0 ]]; then
    echo "/dev/$LVM_VG/${USB_LVS[0]}"
  else
    local next=$(( (idx + 1) % ${#USB_LVS[@]} ))
    echo "/dev/$LVM_VG/${USB_LVS[$next]}"
  fi
}

persist_manifest_for() {
  local root="$1"
  if [[ ! -d "$root" ]]; then
    echo ""
    return 0
  fi
  python3 - <<'PY' "$root"
import hashlib, os, sys
from pathlib import Path

root = Path(sys.argv[1])
if not root.exists():
    print("")
    raise SystemExit(0)

entries = []
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        p = Path(dirpath) / name
        try:
            st = p.stat()
        except FileNotFoundError:
            continue
        if not p.is_file():
            continue
        rel = p.relative_to(root).as_posix()
        entries.append(f"{rel}\t{int(st.st_size)}\t{int(st.st_mtime)}")
entries.sort()
h = hashlib.sha256()
for line in entries:
    h.update(line.encode("utf-8"))
    h.update(b"\n")
print(h.hexdigest())
PY
}

persist_sync_dir() {
  local src="$1" dst="$2"
  safe_mkdir "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src" "$dst"
  else
    rm -rf "$dst"
    safe_mkdir "$dst"
    cp -a "$src/." "$dst/"
  fi
}

persist_check_next() {
  local next_dev="$1"
  if [[ ! -f "$USB_PERSIST_MANIFEST" ]]; then
    log "persist manifest missing: $USB_PERSIST_MANIFEST"
    return 0
  fi
  local expected
  # The sync writes digest=/count=/mode= lines (vision_sync
  # write_manifest_state). Comparing the whole file with a bare digest never
  # matched: every rotation logged a "mismatch" and blindly rewrote the next
  # drive's folder — the check itself never worked. (An older rotator wrote
  # the bare digest: accepted too.)
  expected=$(sed -n 's/^digest=//p' "$USB_PERSIST_MANIFEST" 2>/dev/null | head -1 || true)
  if [[ -z "$expected" ]]; then
    expected=$(head -1 "$USB_PERSIST_MANIFEST" 2>/dev/null | tr -d '[:space:]' || true)
  fi
  if [[ -z "$expected" ]]; then
    log "persist manifest empty"
    return 0
  fi
  safe_mkdir "$PERSIST_MNT"
  if mount -t vfat -o ro,utf8,shortname=mixed,nodev,nosuid,noexec "$next_dev" "$PERSIST_MNT"; then
    actual=$(persist_manifest_for "$PERSIST_MNT/$USB_PERSIST_DIR")
    umount "$PERSIST_MNT" || true
    if [[ "$actual" != "$expected" ]]; then
      log "persist mismatch on $(basename "$next_dev") (expected $expected, got $actual)"
      if [[ -d "$USB_PERSIST_BACKING" ]]; then
        if mount -t vfat -o utf8,shortname=mixed,nodev,nosuid,noexec "$next_dev" "$PERSIST_MNT"; then
          safe_mkdir "$PERSIST_MNT/$USB_PERSIST_DIR"
          persist_sync_dir "$USB_PERSIST_BACKING/" "$PERSIST_MNT/$USB_PERSIST_DIR/"
          repaired=$(persist_manifest_for "$PERSIST_MNT/$USB_PERSIST_DIR")
          umount "$PERSIST_MNT" || true
          if [[ -n "$repaired" ]]; then
            printf 'digest=%s\ncount=0\nmode=active\n' "$repaired" > "$USB_PERSIST_MANIFEST" 2>/dev/null || true
          fi
          log "persist repaired on $(basename "$next_dev")"
        else
          log "persist repair mount failed for $next_dev"
        fi
      else
        log "persist backing missing: $USB_PERSIST_BACKING"
      fi
    else
      log "persist ok on $(basename "$next_dev")"
    fi
  else
    log "persist check mount failed for $next_dev"
  fi
}

rotation_due() {
  [[ -f "$STATE_FILE" ]] || return 1
  state=$(grep '^state=' "$STATE_FILE" | cut -d= -f2)
  active=$(cat "$ACTIVE_FILE" 2>/dev/null || true)
  [[ -n "$state" && -n "$active" ]] || return 1
  if [[ "$state" == "panic" ]]; then
    return 0
  fi
  [[ "$state" == "rotate_pending" ]] && within_window
}

rotation_due || exit 0

# One switch/export/format at a time (usb_lock, common.sh) — and decided again
# once held: a rotation that ran meanwhile may have done this one's work.
usb_lock
rotation_due || exit 0

old_lv=$(basename "$active")
next_dev=$(next_lv "$active")
next_name=$(basename "$next_dev")
log "switching USB gadget from $old_lv to $next_name"

# The next drive must be ready before the AOI gets it:
# - its last export/reformat finished (interrupted: power, timeout, error) —
#   otherwise the AOI got its old images back with 10-20% free;
# - it holds a FAT at all (a power cut between discard and mkfs left none,
#   and an unformatted drive was handed to the AOI).
# Both are done here, on a drive the AOI does not see. If either fails the
# switch is not made: the AOI keeps its current drive.
if [[ -e "$(usb_maint_marker "$next_name")" ]]; then
  log "$next_name: its last export/reformat did not finish; finishing it first"
  if ! /bin/bash "$SCRIPT_DIR/offline-maint.sh" "$next_name"; then
    log "ERROR: $next_name could not be exported/reformatted; staying on $old_lv"
    exit 1
  fi
elif ! usb_has_fat "$next_dev"; then
  log "$next_name holds no FAT filesystem; formatting it first"
  if ! /bin/bash "$SCRIPT_DIR/offline-maint.sh" "$next_name" --format-only; then
    log "ERROR: $next_name could not be formatted; staying on $old_lv"
    exit 1
  fi
fi

if persist_enabled; then
  # A failure here (a damaged FAT entry: EIO, rsync 23) only means the
  # settings folder was not checked; under set -e it aborted every rotation,
  # panic included, and the AOI's drive filled to 100%.
  persist_check_next "$next_dev" || log "persist check of $next_name failed; switching anyway"
fi

# Marked BEFORE the switch: whatever happens after it, the old drive's images
# get exported before the drive is used again.
touch "$(usb_maint_marker "$old_lv")" || log "WARNING: could not mark $old_lv for export"

/bin/bash "$SCRIPT_DIR/usb-gadget.sh" switch

echo "state=ok" > "$STATE_FILE"
# The export takes minutes; the lock is offline-maint's from here.
usb_unlock
systemctl start "offline-maint@${old_lv}.service"
log "rotation complete"

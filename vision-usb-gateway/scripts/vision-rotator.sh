#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config "${CONF_FILE:-}"

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
  now=$(date +%H%M)
  start=${SWITCH_WINDOW_START/:/}
  end=${SWITCH_WINDOW_END/:/}
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
  expected=$(cat "$USB_PERSIST_MANIFEST" 2>/dev/null || true)
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
            echo "$repaired" > "$USB_PERSIST_MANIFEST" 2>/dev/null || true
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

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

state=$(grep '^state=' "$STATE_FILE" | cut -d= -f2)
active=$(cat "$ACTIVE_FILE" 2>/dev/null || true)

if [[ -z "$state" || -z "$active" ]]; then
  exit 1
fi

do_switch=false
if [[ "$state" == "panic" ]]; then
  do_switch=true
elif [[ "$state" == "rotate_pending" ]]; then
  if within_window; then
    do_switch=true
  fi
fi

if [[ "$do_switch" != "true" ]]; then
  exit 0
fi

old_lv=$(basename "$active")
log "switching USB gadget from $old_lv"

if persist_enabled; then
  next_dev=$(next_lv "$active")
  if [[ -n "$next_dev" ]]; then
    persist_check_next "$next_dev"
  fi
fi

/bin/bash "$(dirname "${BASH_SOURCE[0]}")/usb-gadget.sh" switch

systemctl start "offline-maint@${old_lv}.service"

echo "state=ok" > "$STATE_FILE"
log "rotation complete"

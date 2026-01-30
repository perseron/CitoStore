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
  if [[ -d "$USB_PERSIST_BACKING" ]]; then
    log "persist preseed: $USB_PERSIST_BACKING -> $USB_PERSIST_DIR on $(basename "$next_dev")"
    safe_mkdir "$PERSIST_MNT"
    if mount -t vfat -o utf8,shortname=mixed,nodev,nosuid,noexec "$next_dev" "$PERSIST_MNT"; then
      safe_mkdir "$PERSIST_MNT/$USB_PERSIST_DIR"
      persist_sync_dir "$USB_PERSIST_BACKING/" "$PERSIST_MNT/$USB_PERSIST_DIR/"
      umount "$PERSIST_MNT" || true
    else
      log "persist preseed mount failed for $next_dev"
    fi
  else
    log "persist backing missing: $USB_PERSIST_BACKING"
  fi
fi

/bin/bash "$(dirname "${BASH_SOURCE[0]}")/usb-gadget.sh" switch

systemctl start "offline-maint@${old_lv}.service"

echo "state=ok" > "$STATE_FILE"
log "rotation complete"

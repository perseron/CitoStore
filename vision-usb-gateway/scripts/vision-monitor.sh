#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config "${CONF_FILE:-}"

: "${LVM_VG:=vg0}"
: "${THINPOOL_LV:=usbpool}"
: "${THRESH_HI:=80}"
: "${THRESH_CRIT:=92}"
: "${META_HI:=70}"
: "${META_CRIT:=85}"

ACTIVE_FILE=/run/vision-usb-active
STATE_FILE=/run/vision-rotate.state

active_dev=$(cat "$ACTIVE_FILE" 2>/dev/null || true)
if [[ -z "$active_dev" ]]; then
  log "active device unknown"
  exit 1
fi

lv_name=$(basename "$active_dev")

usage=$(lvs --noheadings -o data_percent "/dev/$LVM_VG/$lv_name" | tr -d ' %' | awk '{print int($1)}')
meta=$(lvs --noheadings -o metadata_percent "/dev/$LVM_VG/$THINPOOL_LV" | tr -d ' %' | awk '{print int($1)}')

state=ok
reason="usage=${usage} meta=${meta}"

if [[ $usage -ge $THRESH_CRIT || $meta -ge $META_CRIT ]]; then
  state=panic
elif [[ $usage -ge $THRESH_HI || $meta -ge $META_HI ]]; then
  state=rotate_pending
fi

echo "state=$state" > "$STATE_FILE"
echo "active=$active_dev" >> "$STATE_FILE"
echo "reason=$reason" >> "$STATE_FILE"

log "rotate state: $state ($reason)"

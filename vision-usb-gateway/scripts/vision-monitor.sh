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
: "${THRESH_HI_STABLE_SCANS:=3}"
: "${META_HI:=70}"
: "${META_CRIT:=85}"

ACTIVE_FILE=/run/vision-usb-active
STATE_FILE=/run/vision-rotate.state
USB_USAGE_FILE=/run/vision-usb-usage.json
USAGE_STABLE_FILE=/run/vision-usage-stable.state

to_int_percent() {
  local raw="${1:-}"
  raw=$(echo "$raw" | tr -d '[:space:]%<>' )
  if [[ -z "$raw" ]]; then
    echo ""
    return
  fi
  if [[ "$raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    awk -v v="$raw" 'BEGIN{print int(v)}'
    return
  fi
  echo ""
}

cached_usage_percent() {
  local active="$1"
  [[ -f "$USB_USAGE_FILE" ]] || { echo ""; return; }
  python3 - "$USB_USAGE_FILE" "$active" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
active = sys.argv[2]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
if payload.get("lv") != active:
    print("")
    raise SystemExit(0)
percent = str(payload.get("percent", "")).strip().replace("%", "")
try:
    print(int(float(percent)))
except Exception:
    print("")
PY
}

usage_signature() {
  local raw="${1:-}" parsed="${2:-0}"
  raw=$(echo "$raw" | tr -d '[:space:]')
  if [[ -n "$raw" ]]; then
    echo "$raw"
  else
    echo "$parsed"
  fi
}

usage_stable_count() {
  local active="$1" sig="$2"
  local prev_active="" prev_sig="" prev_count=0
  if [[ -f "$USAGE_STABLE_FILE" ]]; then
    prev_active=$(grep '^active=' "$USAGE_STABLE_FILE" | cut -d= -f2- || true)
    prev_sig=$(grep '^sig=' "$USAGE_STABLE_FILE" | cut -d= -f2- || true)
    prev_count=$(grep '^count=' "$USAGE_STABLE_FILE" | cut -d= -f2- || true)
  fi
  if [[ ! "$prev_count" =~ ^[0-9]+$ ]]; then
    prev_count=0
  fi
  local count=1
  if [[ "$prev_active" == "$active" && "$prev_sig" == "$sig" ]]; then
    count=$((prev_count + 1))
  fi
  {
    echo "active=$active"
    echo "sig=$sig"
    echo "count=$count"
  } > "$USAGE_STABLE_FILE"
  echo "$count"
}

active_dev=$(cat "$ACTIVE_FILE" 2>/dev/null || true)
if [[ -z "$active_dev" ]]; then
  log "active device unknown"
  exit 1
fi

lv_name=$(basename "$active_dev")

usage_raw=$(lvs --noheadings -o data_percent "/dev/$LVM_VG/$lv_name" 2>/dev/null | awk 'NF{print $1; exit}')
usage=$(to_int_percent "$usage_raw")
if [[ -z "$usage" ]]; then
  usage=0
fi

fs_usage=$(cached_usage_percent "$active_dev")
if [[ -n "$fs_usage" && "$fs_usage" =~ ^[0-9]+$ && $fs_usage -gt $usage ]]; then
  usage=$fs_usage
fi

meta_raw=$(lvs --noheadings -o metadata_percent "/dev/$LVM_VG/$THINPOOL_LV" 2>/dev/null | awk 'NF{print $1; exit}')
meta=$(to_int_percent "$meta_raw")
if [[ -z "$meta" ]]; then
  meta=0
fi
sig=$(usage_signature "$usage_raw" "$usage")
stable_count=$(usage_stable_count "$active_dev" "$sig")

state=ok
reason="usage=${usage} (lv=${usage_raw:-n/a} fs=${fs_usage:-n/a}) stable=${stable_count}/${THRESH_HI_STABLE_SCANS} meta=${meta} (pool=${meta_raw:-n/a})"

if [[ $usage -ge $THRESH_CRIT || $meta -ge $META_CRIT ]]; then
  state=panic
elif [[ $meta -ge $META_HI ]]; then
  state=rotate_pending
elif [[ $usage -ge $THRESH_HI ]]; then
  if [[ $stable_count -ge $THRESH_HI_STABLE_SCANS ]]; then
    state=rotate_pending
  else
    state=ok
    reason="$reason hold=high-usage-but-changing"
  fi
fi

echo "state=$state" > "$STATE_FILE"
echo "active=$active_dev" >> "$STATE_FILE"
echo "reason=$reason" >> "$STATE_FILE"

log "rotate state: $state ($reason)"

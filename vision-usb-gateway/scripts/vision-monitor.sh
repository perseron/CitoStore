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
: "${FAST_SYNC_MIN_ON_SCANS:=3}"
: "${FAST_SYNC_COOLDOWN_SCANS:=2}"
: "${FAST_SYNC_EXIT_DELTA:=5}"
# Discard the sync-written USB usage reading if older than this (sync stalled);
# fall back to live lvs data_percent so rotation still triggers.
: "${USB_USAGE_STALE_SEC:=180}"
# Health thresholds. SYNC_HEALTH_MAX_AGE_SEC catches a HUNG sync: the
# ExecStopPost health path only fires on completed cycles, so a sync stuck in
# D-state would otherwise leave stale "ok" health while capture is stopped.
: "${SYNC_HEALTH_MAX_AGE_SEC:=900}"
: "${OVERLAY_USAGE_WARN_PCT:=80}"
: "${OVERLAY_USAGE_CRIT_PCT:=95}"
: "${SOC_TEMP_WARN_C:=80}"
: "${SOC_TEMP_CRIT_C:=85}"
: "${USB_GADGET_NAME:=vision}"

ACTIVE_FILE=/run/vision-usb-active
STATE_FILE=/run/vision-rotate.state
USB_USAGE_FILE=/run/vision-usb-usage.json
USAGE_STABLE_FILE=/run/vision-usage-stable.state
FAST_SYNC_STATE_FILE=/run/vision-fast-sync.state
FAST_SYNC_TIMER=vision-sync-fast.timer

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
  python3 - "$USB_USAGE_FILE" "$active" "$USB_USAGE_STALE_SEC" <<'PY'
import json
import os
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
active = sys.argv[2]
stale = int(sys.argv[3])
try:
    age = time.time() - os.path.getmtime(path)
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
# If sync stopped refreshing this file (e.g. sync is failing) the reading is
# frozen and would hide a filling LV. Discard it so the caller falls back to
# the live lvs data_percent and rotation still triggers.
if age > stale:
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
  local raw="${1:-}" parsed="${2:-0}" source="${3:-lv}"
  raw=$(echo "$raw" | tr -d '[:space:]')
  if [[ "$source" == "lv" && -n "$raw" ]]; then
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

set_fast_sync_mode() {
  local enabled="$1"
  if [[ "$enabled" == "true" ]]; then
    systemctl start "$FAST_SYNC_TIMER" >/dev/null 2>&1 || true
  else
    systemctl stop "$FAST_SYNC_TIMER" >/dev/null 2>&1 || true
  fi
}

load_fast_sync_state() {
  fast_enabled=0
  fast_on_scans=0
  fast_cooldown=0
  if [[ -f "$FAST_SYNC_STATE_FILE" ]]; then
    fast_enabled=$(grep '^enabled=' "$FAST_SYNC_STATE_FILE" | cut -d= -f2- || echo 0)
    fast_on_scans=$(grep '^on_scans=' "$FAST_SYNC_STATE_FILE" | cut -d= -f2- || echo 0)
    fast_cooldown=$(grep '^cooldown=' "$FAST_SYNC_STATE_FILE" | cut -d= -f2- || echo 0)
  fi
  [[ "$fast_enabled" =~ ^[01]$ ]] || fast_enabled=0
  [[ "$fast_on_scans" =~ ^[0-9]+$ ]] || fast_on_scans=0
  [[ "$fast_cooldown" =~ ^[0-9]+$ ]] || fast_cooldown=0
}

save_fast_sync_state() {
  {
    echo "enabled=$fast_enabled"
    echo "on_scans=$fast_on_scans"
    echo "cooldown=$fast_cooldown"
  } > "$FAST_SYNC_STATE_FILE"
}

active_dev=$(cat "$ACTIVE_FILE" 2>/dev/null || true)
if [[ -z "$active_dev" ]]; then
  log "active device unknown"
  exit 1
fi

lv_name=$(basename "$active_dev")

usage_raw=$(lvs --noheadings -o data_percent "/dev/$LVM_VG/$lv_name" 2>/dev/null | awk 'NF{print $1; exit}')
usage_lv=$(to_int_percent "$usage_raw")
if [[ -z "$usage_lv" ]]; then
  usage_lv=0
fi

fs_usage=$(cached_usage_percent "$active_dev")
usage_source="lv"
usage=$usage_lv
if [[ -n "$fs_usage" && "$fs_usage" =~ ^[0-9]+$ ]]; then
  # Prefer filesystem fullness when available; LV data_percent can stay high after prior writes.
  usage=$fs_usage
  usage_source="fs"
fi

meta_raw=$(lvs --noheadings -o metadata_percent "/dev/$LVM_VG/$THINPOOL_LV" 2>/dev/null | awk 'NF{print $1; exit}')
meta=$(to_int_percent "$meta_raw")
if [[ -z "$meta" ]]; then
  meta=0
fi
sig=$(usage_signature "$usage_raw" "$usage" "$usage_source")
stable_count=$(usage_stable_count "$active_dev" "$sig")
load_fast_sync_state

state=ok
reason="usage=${usage} src=${usage_source} (lv=${usage_raw:-n/a} fs=${fs_usage:-n/a}) stable=${stable_count}/${THRESH_HI_STABLE_SCANS} meta=${meta} (pool=${meta_raw:-n/a})"
fast_desired=false
fast_forced_off=false

if [[ $usage -ge $THRESH_CRIT || $meta -ge $META_CRIT ]]; then
  state=panic
  fast_forced_off=true
elif [[ $meta -ge $META_HI ]]; then
  state=rotate_pending
  fast_forced_off=true
elif [[ $usage -ge $THRESH_HI ]]; then
  if [[ $stable_count -ge $THRESH_HI_STABLE_SCANS ]]; then
    state=rotate_pending
    fast_forced_off=true
  else
    state=ok
    reason="$reason hold=high-usage-but-changing"
    fast_desired=true
  fi
fi

if [[ "$fast_forced_off" == "true" ]]; then
  fast_enabled=0
  fast_on_scans=0
  fast_cooldown=$FAST_SYNC_COOLDOWN_SCANS
  set_fast_sync_mode false
elif [[ "$fast_desired" == "true" ]]; then
  if [[ $fast_enabled -eq 1 ]]; then
    fast_on_scans=$((fast_on_scans + 1))
    set_fast_sync_mode true
  else
    if [[ $fast_cooldown -gt 0 ]]; then
      fast_cooldown=$((fast_cooldown - 1))
      reason="$reason fast_sync=cooldown(${fast_cooldown})"
    else
      fast_enabled=1
      fast_on_scans=1
      set_fast_sync_mode true
      reason="$reason fast_sync=on"
    fi
  fi
else
  # Hysteresis: keep fast mode briefly to avoid flapping near THRESH_HI.
  keep_floor=$((THRESH_HI - FAST_SYNC_EXIT_DELTA))
  if [[ $keep_floor -lt 0 ]]; then
    keep_floor=0
  fi
  if [[ $fast_enabled -eq 1 && $fast_on_scans -lt $FAST_SYNC_MIN_ON_SCANS && $usage -ge $keep_floor ]]; then
    fast_on_scans=$((fast_on_scans + 1))
    set_fast_sync_mode true
    reason="$reason fast_sync=hold(${fast_on_scans}/${FAST_SYNC_MIN_ON_SCANS})"
  else
    fast_enabled=0
    fast_on_scans=0
    if [[ $FAST_SYNC_COOLDOWN_SCANS -gt 0 ]]; then
      fast_cooldown=$FAST_SYNC_COOLDOWN_SCANS
    fi
    set_fast_sync_mode false
  fi
fi
save_fast_sync_state

echo "state=$state" > "$STATE_FILE"
echo "active=$active_dev" >> "$STATE_FILE"
echo "reason=$reason" >> "$STATE_FILE"

# --- system-level liveness checks (computed once, reported by write_health) ---

sync_stale_msg=""
if [[ -f "$USB_USAGE_FILE" ]]; then
  sync_age=$(( $(date +%s) - $(stat -c %Y "$USB_USAGE_FILE" 2>/dev/null || echo 0) ))
  if (( sync_age > SYNC_HEALTH_MAX_AGE_SEC )); then
    sync_stale_msg="sync stalled: last completed cycle ${sync_age}s ago"
  fi
elif systemctl is-active --quiet vision-sync.timer 2>/dev/null; then
  sync_stale_msg="sync has not completed a cycle since boot"
fi

# An unbound UDC means the AOI sees no drive at all — without this check that
# failure mode leaves health green.
gadget_msg=""
gadget_udc_file="/sys/kernel/config/usb_gadget/${USB_GADGET_NAME}/UDC"
if [[ -f "$gadget_udc_file" && -z "$(cat "$gadget_udc_file" 2>/dev/null)" ]]; then
  gadget_msg="USB gadget not bound to UDC (AOI sees no drive)"
fi

# The root overlay upper is tmpfs: filling it costs RAM first (OOM on 2GB
# units) and ends in ENOSPC on /.
overlay_pct=$(df --output=pcent / 2>/dev/null | awk 'NR==2 {gsub(/[ %]/,""); print}')

soc_temp_c=""
soc_temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "")
[[ "$soc_temp_raw" =~ ^[0-9]+$ ]] && soc_temp_c=$((soc_temp_raw / 1000))

# Write health JSON for WebUI /api/health (refreshed every monitor cycle)
write_health() {
  local health_status="ok"
  local issues=()
  if [[ "$state" == "panic" ]]; then
    health_status="error"
    issues+=("USB usage critical (${usage}%)")
  elif [[ "$state" == "rotate_pending" ]]; then
    health_status="warn"
    issues+=("USB rotation pending (${usage}%)")
  fi
  if [[ $meta -ge $META_CRIT ]]; then
    health_status="error"
    issues+=("Thinpool metadata critical (${meta}%)")
  elif [[ $meta -ge $META_HI ]]; then
    [[ "$health_status" == "ok" ]] && health_status="warn"
    issues+=("Thinpool metadata high (${meta}%)")
  fi
  # A failed sync cycle ($SERVICE_RESULT is set by systemd for ExecStopPost)
  # must surface as an error; otherwise a broken sync leaves stale "ok" health
  # while the device has silently stopped backing up.
  if [[ -n "${SERVICE_RESULT:-}" && "${SERVICE_RESULT}" != "success" ]]; then
    health_status="error"
    issues+=("sync cycle failed: ${SERVICE_RESULT}")
  fi
  if [[ -n "$sync_stale_msg" ]]; then
    health_status="error"
    issues+=("$sync_stale_msg")
  fi
  if [[ -n "$gadget_msg" ]]; then
    health_status="error"
    issues+=("$gadget_msg")
  fi
  if [[ -n "$overlay_pct" ]]; then
    if (( overlay_pct >= OVERLAY_USAGE_CRIT_PCT )); then
      health_status="error"
      issues+=("root overlay ${overlay_pct}% full (tmpfs eats RAM)")
    elif (( overlay_pct >= OVERLAY_USAGE_WARN_PCT )); then
      [[ "$health_status" == "ok" ]] && health_status="warn"
      issues+=("root overlay ${overlay_pct}% full (tmpfs eats RAM)")
    fi
  fi
  if [[ -n "$soc_temp_c" ]]; then
    if (( soc_temp_c >= SOC_TEMP_CRIT_C )); then
      health_status="error"
      issues+=("SoC temperature ${soc_temp_c}C (throttling)")
    elif (( soc_temp_c >= SOC_TEMP_WARN_C )); then
      [[ "$health_status" == "ok" ]] && health_status="warn"
      issues+=("SoC temperature ${soc_temp_c}C")
    fi
  fi
  local out="$1"
  {
    echo '{'
    echo "  \"status\": \"${health_status}\","
    echo "  \"issues\": ["
    for i in "${!issues[@]}"; do
      local sep=","
      [[ $i -eq $((${#issues[@]}-1)) ]] && sep=""
      printf '    "%s"%s\n' "${issues[$i]}" "$sep"
    done
    echo "  ],"
    echo "  \"ts\": \"$(date -Is)\""
    echo '}'
  } > "$out"
}
write_health "/run/vision-health.json"
# Also persist to mirror if mounted
if mountpoint -q /srv/vision_mirror 2>/dev/null; then
  mkdir -p /srv/vision_mirror/.state
  write_health "/srv/vision_mirror/.state/health.json"
fi

log "rotate state: $state ($reason)"

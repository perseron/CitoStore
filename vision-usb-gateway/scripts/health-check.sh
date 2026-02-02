#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config

log "health-check start"

GATEWAY_HOME=${GATEWAY_HOME:-/opt/vision-usb-gateway}
MIRROR_MOUNT=${MIRROR_MOUNT:-/srv/vision_mirror}
STATE_DIR="$MIRROR_MOUNT/.state"
DEFAULT_CONF="$GATEWAY_HOME/conf/vision-gw.conf.example"
ACTIVE_FILE=${USB_ACTIVE_PERSIST:-$STATE_DIR/vision-usb-active}
VG="${LVM_VG:-vg0}"
USB_LVS=("${USB_LVS[@]:-usb_0 usb_1 usb_2}")
SNAP_NAME=${SYNC_SNAPSHOT_NAME:-usb_sync_snap}

if ! mountpoint -q "$MIRROR_MOUNT"; then
  log "mirror not mounted: $MIRROR_MOUNT"
else
  mkdir -p "$STATE_DIR"
fi

# Ensure shadow config exists; fall back to default.
if [[ ! -f "$STATE_DIR/vision-gw.conf" && -f "$DEFAULT_CONF" ]]; then
  log "shadow config missing; restoring default"
  cp "$DEFAULT_CONF" "$STATE_DIR/vision-gw.conf"
fi

# Ensure GATEWAY_HOME is present in shadow config.
if [[ -f "$STATE_DIR/vision-gw.conf" ]]; then
  if grep -q '^GATEWAY_HOME=' "$STATE_DIR/vision-gw.conf"; then
    sed -i "s#^GATEWAY_HOME=.*#GATEWAY_HOME=$GATEWAY_HOME#" "$STATE_DIR/vision-gw.conf"
  else
    echo "GATEWAY_HOME=$GATEWAY_HOME" >> "$STATE_DIR/vision-gw.conf"
  fi
fi

# Cleanup stale snapshot LV if it exists.
if command -v lvs >/dev/null 2>&1; then
  if lvs "$VG/$SNAP_NAME" >/dev/null 2>&1; then
    log "stale snapshot detected: $VG/$SNAP_NAME (removing)"
    lvremove -f "$VG/$SNAP_NAME" || true
  fi
fi

# Validate active USB LV pointer.
if [[ -n "${ACTIVE_FILE:-}" ]]; then
  if [[ -f "$ACTIVE_FILE" ]]; then
    active=$(cat "$ACTIVE_FILE" | tr -d '[:space:]')
  else
    active=""
  fi
  if [[ -z "$active" || ! -e "$active" ]]; then
    log "active LV missing; selecting first available"
    for lv in "${USB_LVS[@]}"; do
      if [[ -e "/dev/$VG/$lv" ]]; then
        echo "/dev/$VG/$lv" > "$ACTIVE_FILE"
        active="/dev/$VG/$lv"
        log "active LV set to $active"
        break
      fi
    done
  fi
fi

# Check sqlite state DB; if unreadable, move aside.
DB_FILE="$STATE_DIR/vision.db"
if [[ -f "$DB_FILE" ]]; then
  if ! python3 - <<'PY' "$DB_FILE"
import sqlite3, sys
path = sys.argv[1]
try:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA quick_check;").fetchall()
    conn.close()
except Exception:
    raise SystemExit(1)
PY
  then
    log "vision.db failed quick_check; moving aside"
    mv "$DB_FILE" "$DB_FILE.corrupt.$(date +%s)" || true
  fi
fi

log "health-check complete"

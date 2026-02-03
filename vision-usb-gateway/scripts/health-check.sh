#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config

log "health-check start"

HEALTH_STATE="$STATE_DIR/health.json"
HEALTH_STATUS="ok"
HEALTH_ISSUES=()

health_warn() {
  HEALTH_STATUS="warn"
  HEALTH_ISSUES+=("$1")
  log "health: $1"
}

GATEWAY_HOME=${GATEWAY_HOME:-/opt/vision-usb-gateway}
MIRROR_MOUNT=${MIRROR_MOUNT:-/srv/vision_mirror}
STATE_DIR="$MIRROR_MOUNT/.state"
DEFAULT_CONF="$GATEWAY_HOME/conf/vision-gw.conf.example"
DEFAULT_CREDS="$GATEWAY_HOME/conf/nas/vision-nas.creds.example"
LAST_GOOD_CONF="$STATE_DIR/vision-gw.conf.last-good"
ACTIVE_FILE=${USB_ACTIVE_PERSIST:-$STATE_DIR/vision-usb-active}
VG="${LVM_VG:-vg0}"
MIRROR_LV="${MIRROR_LV:-mirror}"
USB_LVS=("${USB_LVS[@]:-usb_0 usb_1 usb_2}")
SNAP_NAME=${SYNC_SNAPSHOT_NAME:-usb_sync_snap}
HEALTHCHECK_FSCK_MIRROR=${HEALTHCHECK_FSCK_MIRROR:-true}
HEALTHCHECK_FSCK_USB=${HEALTHCHECK_FSCK_USB:-true}
USB_LABEL=${USB_LABEL:-VISIONUSB}

if ! mountpoint -q "$MIRROR_MOUNT"; then
  health_warn "mirror not mounted: $MIRROR_MOUNT"
else
  mkdir -p "$STATE_DIR"
fi

# Ensure shadow config exists; fall back to default.
if [[ ! -f "$STATE_DIR/vision-gw.conf" && -f "$DEFAULT_CONF" ]]; then
  log "shadow config missing; restoring default"
  cp "$DEFAULT_CONF" "$STATE_DIR/vision-gw.conf"
  health_warn "shadow config missing; default restored"
fi

# If shadow config looks invalid, rollback to last-good or default.
if [[ -f "$STATE_DIR/vision-gw.conf" ]]; then
  if ! grep -q '^GATEWAY_HOME=' "$STATE_DIR/vision-gw.conf"; then
    if [[ -f "$LAST_GOOD_CONF" ]]; then
      log "shadow config invalid; restoring last-good"
      cp "$LAST_GOOD_CONF" "$STATE_DIR/vision-gw.conf"
      health_warn "shadow config invalid; restored last-good"
    elif [[ -f "$DEFAULT_CONF" ]]; then
      log "shadow config invalid; restoring default"
      cp "$DEFAULT_CONF" "$STATE_DIR/vision-gw.conf"
      health_warn "shadow config invalid; restored default"
    fi
  fi
fi

# Ensure shadow NAS creds exists if system creds exist (overlay-safe).
if [[ ! -f "$STATE_DIR/vision-nas.creds" ]]; then
  if [[ -f /etc/vision-nas.creds ]]; then
    log "shadow NAS creds missing; copying from /etc"
    cp /etc/vision-nas.creds "$STATE_DIR/vision-nas.creds"
    chmod 0600 "$STATE_DIR/vision-nas.creds"
  elif [[ -f "$DEFAULT_CREDS" ]]; then
    log "shadow NAS creds missing; installing default example"
    cp "$DEFAULT_CREDS" "$STATE_DIR/vision-nas.creds"
    chmod 0600 "$STATE_DIR/vision-nas.creds"
  fi
fi

# Validate shadow NAS creds format (username/password lines).
if [[ -f "$STATE_DIR/vision-nas.creds" ]]; then
  if ! grep -q '^username=' "$STATE_DIR/vision-nas.creds" || ! grep -q '^password=' "$STATE_DIR/vision-nas.creds"; then
    log "shadow NAS creds missing username/password; resetting to example"
    if [[ -f "$DEFAULT_CREDS" ]]; then
      cp "$DEFAULT_CREDS" "$STATE_DIR/vision-nas.creds"
      chmod 0600 "$STATE_DIR/vision-nas.creds"
    fi
  fi
  chmod 0600 "$STATE_DIR/vision-nas.creds" || true
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
    health_warn "stale snapshot removed: $VG/$SNAP_NAME"
  fi
fi

# Run fsck on mirror LV if not mounted.
if [[ "$HEALTHCHECK_FSCK_MIRROR" == "true" ]]; then
  if ! mountpoint -q "$MIRROR_MOUNT"; then
    if command -v fsck >/dev/null 2>&1; then
      log "fsck on /dev/$VG/$MIRROR_LV"
      fsck -p "/dev/$VG/$MIRROR_LV" || true
    fi
  else
    log "mirror mounted; skipping fsck"
  fi
fi

# Run fsck on inactive USB LVs (FAT32) if possible.
if [[ "$HEALTHCHECK_FSCK_USB" == "true" ]]; then
  if command -v fsck.fat >/dev/null 2>&1; then
    active=""
    if [[ -f "$ACTIVE_FILE" ]]; then
      active=$(cat "$ACTIVE_FILE" | tr -d '[:space:]')
    fi
    for lv in "${USB_LVS[@]}"; do
      dev="/dev/$VG/$lv"
      if [[ "$dev" == "$active" ]]; then
        continue
      fi
      if [[ -e "$dev" ]]; then
        log "fsck.fat on $dev"
        fsck.fat -a "$dev" || true
      fi
    done
  else
    log "fsck.fat not available; skipping USB fsck"
    health_warn "fsck.fat not available; USB fsck skipped"
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
        health_warn "active LV missing; auto-selected $active"
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
    health_warn "vision.db corrupt; moved aside"
  fi
fi

if mountpoint -q "$MIRROR_MOUNT"; then
  mkdir -p "$STATE_DIR"
  {
    echo '{'
    echo "  \"status\": \"${HEALTH_STATUS}\","
    echo "  \"issues\": ["
    for i in "${!HEALTH_ISSUES[@]}"; do
      sep=","
      [[ $i -eq $((${#HEALTH_ISSUES[@]}-1)) ]] && sep=""
      printf '    "%s"%s\n' "${HEALTH_ISSUES[$i]}" "$sep"
    done
    echo "  ],"
    echo "  \"ts\": \"$(date -Is)\""
    echo '}'
  } > "$HEALTH_STATE"
fi

log "health-check complete"

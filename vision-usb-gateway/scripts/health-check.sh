#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config

log "health-check start"
HEALTH_STATUS="ok"
HEALTH_ISSUES=()

health_warn() {
  HEALTH_STATUS="warn"
  HEALTH_ISSUES+=("$1")
  log "health: $1"
}

# GATEWAY_HOME comes from common.sh (env override or self-derived).
MIRROR_MOUNT=${MIRROR_MOUNT:-/srv/vision_mirror}
STATE_DIR="$MIRROR_MOUNT/.state"
HEALTH_STATE="$STATE_DIR/health.json"
HEALTH_STATE_FALLBACK="/run/vision-health.json"
# The unit's factory config (golden image), not the generic example.
DEFAULT_CONF=$(golden_conf || true)
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

# Runs with the overlay off only on the first boot after a flash or in a
# deliberate maintenance cycle; any other time (overlay enable failed) every
# write lands on the eMMC and wears it.
if [[ "$(findmnt -no FSTYPE / 2>/dev/null || true)" != "overlay" && -f /etc/citostore-firstboot-done ]]; then
  health_warn "read-only root overlay is OFF (writes go to the eMMC)"
fi

MIRROR_OK=false
if ! mountpoint -q "$MIRROR_MOUNT"; then
  health_warn "mirror not mounted: $MIRROR_MOUNT"
else
  MIRROR_OK=true
  mkdir -p "$STATE_DIR"
fi

# Self-heal an incomplete NVMe layout. A factory reset / provision creates the
# USB LVs LAST, so if that step is interrupted the unit can boot with the thin
# pool present but usb_0..2 missing — seen for real when a power loss (no
# supplementary supply) hit mid-wipe: usb-gadget then cannot open its backing
# files and there was no automatic way back, only manual repair. We run
# Before=usb-gadget.service, so complete the layout here via the idempotent
# 30_setup (no --wipe: it only creates what is missing and never repartitions).
# Gated on the pool existing + at least one USB LV missing, so a healthy boot
# does nothing.
THINPOOL_LV="${THINPOOL_LV:-usbpool}"
if lvs "$VG/$THINPOOL_LV" >/dev/null 2>&1; then
  usb_lv_missing=false
  for _lv in "${USB_LVS[@]}"; do
    lvs "$VG/$_lv" >/dev/null 2>&1 || usb_lv_missing=true
  done
  if [[ "$usb_lv_missing" == true ]]; then
    log "USB LV(s) missing under existing pool; completing NVMe layout (interrupted-rebuild recovery)"
    if bash "$GATEWAY_HOME/install/30_setup_nvme_lvm.sh" >/dev/null 2>&1; then
      health_warn "USB LV(s) were missing; NVMe layout auto-completed"
    else
      health_warn "USB LV(s) missing and auto-complete failed"
    fi
  fi
fi

# Everything down to the snapshot cleanup reads/writes the NVMe's .state. With
# the mirror not mounted there is none: these cp's used to abort the whole check
# under set -e, before any health JSON was written - so the one boot that most
# needed the "mirror not mounted" banner never showed it.
if [[ "$MIRROR_OK" == true ]]; then

# Ensure shadow config exists. Seed it from this image's own /etc config (the
# golden, tuned one - this runs before update-config) rather than the generic
# example, which has ingest/eth1 off and generic names.
if [[ ! -f "$STATE_DIR/vision-gw.conf" ]]; then
  if [[ -f /etc/vision-gw.conf ]] && grep -q '^GATEWAY_HOME=' /etc/vision-gw.conf; then
    log "shadow config missing; seeding it from /etc/vision-gw.conf"
    cp /etc/vision-gw.conf "$STATE_DIR/vision-gw.conf"
    health_warn "shadow config missing; seeded from the image's config"
  elif [[ -f "$DEFAULT_CONF" ]]; then
    log "shadow config missing; restoring default"
    cp "$DEFAULT_CONF" "$STATE_DIR/vision-gw.conf"
    health_warn "shadow config missing; default restored"
  fi
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

fi  # MIRROR_OK

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
FSCK_RESULTS=()
if [[ "$HEALTHCHECK_FSCK_USB" == "true" ]]; then
  if command -v fsck.fat >/dev/null 2>&1; then
    active=""
    if [[ -f "$ACTIVE_FILE" ]]; then
      active=$(cat "$ACTIVE_FILE" | tr -d '[:space:]')
    fi
    # At boot this service is ordered Before=usb-gadget, so the active LV is not
    # exposed to the AOI yet — the one chance to repair a FAT the AOI was
    # mid-write on when power was cut. Once the gadget is up, touching the
    # active LV would corrupt the host's cached FAT, so it is skipped.
    gadget_active=false
    systemctl is-active --quiet usb-gadget.service 2>/dev/null && gadget_active=true
    for lv in "${USB_LVS[@]}"; do
      dev="/dev/$VG/$lv"
      if [[ "$dev" == "$active" && "$gadget_active" == "true" ]]; then
        FSCK_RESULTS+=("{\"lv\":\"$lv\",\"status\":\"skipped (active)\"}")
        continue
      fi
      # A blank drive (formatted below): fsck.fat exits 1 on it too, which
      # read as "repaired the FAT".
      if [[ -e "$dev" ]] && usb_is_blank "$dev"; then
        FSCK_RESULTS+=("{\"lv\":\"$lv\",\"status\":\"blank\"}")
        continue
      fi
      if [[ -e "$dev" ]]; then
        log "fsck.fat on $dev"
        # rc captured properly: "$(...) || true; rc=$?" always read 0, so a
        # repaired or broken FAT was never reported. fsck.fat -a: 0 clean,
        # 1 errors found and fixed, anything else could not be repaired.
        fsck_rc=0
        fsck_out=$(fsck.fat -a "$dev" 2>&1) || fsck_rc=$?
        fsck_status="ok"
        if [[ $fsck_rc -eq 1 ]] && fsck_fat_only_bookkeeping "$fsck_out"; then
          fsck_status="ok (free-space count / dirty flag corrected)"
        elif [[ $fsck_rc -eq 1 ]]; then
          fsck_status="repaired"
          health_warn "fsck.fat repaired the FAT on $lv"
        elif [[ $fsck_rc -ne 0 ]]; then
          fsck_status="FAIL (rc=$fsck_rc)"
          health_warn "fsck.fat failed on $lv"
        fi
        # Substring, not "| head -c": under pipefail a long output gets SIGPIPE.
        fsck_out_escaped=$(printf '%s' "${fsck_out:0:200}" | tr '"' "'" | tr '\n' ' ')
        FSCK_RESULTS+=("{\"lv\":\"$lv\",\"status\":\"$fsck_status\",\"output\":\"$fsck_out_escaped\"}")
      fi
    done
  else
    log "fsck.fat not available; skipping USB fsck"
    health_warn "fsck.fat not available; USB fsck skipped"
  fi
fi
# Write USB fsck results to JSON
{
  echo '{"lvs":['
  for i in "${!FSCK_RESULTS[@]}"; do
    sep=","
    [[ $i -eq $((${#FSCK_RESULTS[@]}-1)) ]] && sep=""
    echo "  ${FSCK_RESULTS[$i]}${sep}"
  done
  echo "],"
  echo "\"ts\": \"$(date -Is)\"}"
} > "$STATE_DIR/usb-fsck.json" 2>/dev/null || true

# Drives that cannot be used as they are, while none is exported yet:
# - blank, no filesystem at all (a power cut between discard/create and mkfs in a factory
#   reset, self-heal, resize or offline-maint): exported anyway before, and
#   nothing ever reformatted it — formatted now (nothing on it to save);
# - an export/reformat that never finished (usb_maint_marker): finished in
#   the background (it needs the mirror and takes minutes), the AOI's own
#   drive is not one of them.
if ! systemctl is-active --quiet usb-gadget.service 2>/dev/null; then
  boot_active=$(tr -d '[:space:]' < "$ACTIVE_FILE" 2>/dev/null || true)
  for lv in "${USB_LVS[@]}"; do
    dev="/dev/$VG/$lv"
    [[ -e "$dev" ]] || continue
    if usb_is_blank "$dev"; then
      log "$lv is blank (no filesystem): formatting it"
      if bash "$SCRIPT_DIR/offline-maint.sh" "$lv" --format-only; then
        health_warn "$lv was blank (no filesystem); formatted"
        rm -f "$(usb_maint_marker "$lv")"
      else
        health_warn "$lv is blank (no filesystem) and could not be formatted"
      fi
    elif [[ "$MIRROR_OK" == true && -e "$(usb_maint_marker "$lv")" && "$dev" != "$boot_active" ]]; then
      log "$lv: its export/reformat did not finish; resuming it in the background"
      health_warn "$lv: unfinished export/reformat resumed"
      systemctl --no-block start "offline-maint@$lv.service" || true
    fi
  done
fi

# The AOI's settings folder on every USB drive (usb_persist_write in common.sh).
# Every boot, after fsck and still Before=usb-gadget: no drive is exported to
# the host yet, so each can be mounted. A drive that lacks the folder — every
# LV fresh from install / first boot / factory reset / a self-heal used to —
# gets it back, filled from the NVMe copy. Needs the mirror (the copy lives
# there); without it the next boot does it. A run with the gadget up (not the
# boot path) leaves the exported drive alone.
: "${USB_PERSIST_DIR:=aoi_settings}"
: "${USB_PERSIST_BACKING:=$STATE_DIR/$USB_PERSIST_DIR}"
PERSIST_RESULTS=()
if [[ "$MIRROR_OK" == true && -n "$USB_PERSIST_DIR" && "$USB_PERSIST_DIR" != none ]]; then
  mkdir -p "$USB_PERSIST_BACKING"
  exported=""
  if systemctl is-active --quiet usb-gadget.service 2>/dev/null && [[ -f "$ACTIVE_FILE" ]]; then
    exported=$(tr -d '[:space:]' < "$ACTIVE_FILE")
  fi
  for lv in "${USB_LVS[@]}"; do
    dev="/dev/$VG/$lv"
    [[ -e "$dev" && "$dev" != "$exported" ]] || continue
    if ! st=$(usb_persist_write "$dev" "$USB_PERSIST_BACKING" ensure); then
      st="unchecked (mount failed)"
      health_warn "$lv: could not check the $USB_PERSIST_DIR folder (mount failed)"
    elif [[ "$st" != ok ]]; then
      log "$lv: $USB_PERSIST_DIR folder was missing; $st"
      health_warn "$lv: $USB_PERSIST_DIR folder was missing; $st"
    fi
    PERSIST_RESULTS+=("$lv=$st")
  done
  log "$USB_PERSIST_DIR folder check: ${PERSIST_RESULTS[*]:-no drives}"
fi

# Validate active USB LV pointer (it lives on the NVMe).
if [[ "$MIRROR_OK" == true && -n "${ACTIVE_FILE:-}" ]]; then
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

write_health() {
  local out="$1"
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
  } > "$out"
}

write_health "$HEALTH_STATE_FALLBACK"
# This boot's findings, kept apart: vision-monitor rewrites health.json after
# every sync (~30 s), so a boot-time repair (FAT fixed, USB LV recreated,
# aoi_settings restored, overlay off) vanished from the WebUI before anyone
# could see it. /run lives exactly as long as this boot; the WebUI merges it.
write_health /run/vision-health-boot.json

if mountpoint -q "$MIRROR_MOUNT"; then
  mkdir -p "$STATE_DIR"
  write_health "$HEALTH_STATE"
fi

log "health-check complete"

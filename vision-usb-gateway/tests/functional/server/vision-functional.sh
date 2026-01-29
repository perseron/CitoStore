#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../scripts/common.sh"

require_root

CONFIG_FILE=/etc/vision-gw.conf
DESTRUCTIVE=false
NAS_SYNC=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --destructive)
      DESTRUCTIVE=true
      shift
      ;;
    --nas-sync)
      NAS_SYNC=true
      shift
      ;;
    -h|--help)
      cat <<'EOF'
vision-functional.sh [--config /etc/vision-gw.conf] [--destructive] [--nas-sync]

Non-destructive functional checks by default.
--destructive enables rotation switching tests (may change active USB LV).
--nas-sync triggers a NAS sync run if NAS_ENABLED=true.
EOF
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

load_config "$CONFIG_FILE"

PASS=0
FAIL=0
WARN=0

pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
warn() { echo "WARN: $*"; WARN=$((WARN+1)); }

need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
}

need_cmd systemctl
need_cmd mountpoint
need_cmd lvs

MIRROR_MOUNT=${MIRROR_MOUNT:-/srv/vision_mirror}
USB_GADGET_NAME=${USB_GADGET_NAME:-vision}
NAS_MOUNT=${NAS_MOUNT:-/mnt/nas}

echo "== Vision USB Gateway functional test (server) =="

# Overlay status (informational)
if cmdline_has "overlayroot=tmpfs:recurse=0"; then
  pass "overlayroot enabled in cmdline"
else
  warn "overlayroot not enabled (maintenance mode?)"
fi

root_fs=$(findmnt -no FSTYPE / || true)
if [[ "$root_fs" == "overlay" ]]; then
  pass "root filesystem is overlay"
else
  warn "root filesystem is $root_fs (expected overlay)"
fi

# USB gadget checks
if systemctl is-active --quiet usb-gadget.service; then
  pass "usb-gadget.service active"
else
  fail "usb-gadget.service not active"
fi

if mountpoint -q /sys/kernel/config; then
  pass "configfs mounted"
else
  fail "configfs not mounted"
fi

udc_list=$(ls /sys/class/udc 2>/dev/null || true)
if [[ -n "$udc_list" ]]; then
  pass "UDC present: $udc_list"
else
  fail "no UDC present"
fi

gadget_udc="/sys/kernel/config/usb_gadget/$USB_GADGET_NAME/UDC"
if [[ -f "$gadget_udc" ]]; then
  bound_udc=$(cat "$gadget_udc" || true)
  if [[ -n "$bound_udc" ]]; then
    pass "gadget bound to UDC: $bound_udc"
  else
    fail "gadget UDC not bound"
  fi
else
  fail "gadget path missing: $gadget_udc"
fi

if [[ -f /run/vision-usb-active ]]; then
  pass "active USB LV set: $(cat /run/vision-usb-active)"
else
  fail "active USB LV file missing"
fi

# Mirror + Samba
if mountpoint -q "$MIRROR_MOUNT"; then
  pass "mirror mount active: $MIRROR_MOUNT"
else
  fail "mirror mount missing: $MIRROR_MOUNT"
fi

if systemctl is-active --quiet smbd; then
  pass "smbd active"
else
  fail "smbd not active"
fi

if [[ -d "$MIRROR_MOUNT/raw" && -d "$MIRROR_MOUNT/bydate" ]]; then
  pass "mirror folders present (raw/bydate)"
else
  warn "mirror folders missing (raw/bydate)"
fi

if command -v testparm >/dev/null 2>&1; then
  if testparm -s >/dev/null 2>&1; then
    pass "samba config parses"
  else
    fail "samba config errors (testparm)"
  fi
fi

# Sync service smoke test
if systemctl start vision-sync.service >/dev/null 2>&1; then
  result=$(systemctl show -p Result --value vision-sync.service || true)
  if [[ "$result" == "success" ]]; then
    pass "vision-sync.service ran successfully"
  else
    fail "vision-sync.service result: $result"
  fi
else
  fail "vision-sync.service failed to start"
fi

if journalctl -u vision-sync.service -n 50 --no-pager | grep -q "synced:"; then
  pass "vision-sync copied files"
else
  warn "vision-sync ran but no new files detected"
fi

# Monitor + rotator
monitor_err=$(mktemp)
if "$SCRIPT_DIR/../../../scripts/vision-monitor.sh" >/dev/null 2>"$monitor_err"; then
  if [[ -f /run/vision-rotate.state ]]; then
    state=$(grep '^state=' /run/vision-rotate.state | cut -d= -f2)
    pass "vision-monitor produced state: $state"
  else
    fail "vision-monitor did not create state file"
  fi
else
  fail "vision-monitor script failed: $(cat "$monitor_err")"
fi
rm -f "$monitor_err"

ROTATE_STATE_BACKUP=""
if [[ -f /run/vision-rotate.state ]]; then
  ROTATE_STATE_BACKUP=$(mktemp)
  cp /run/vision-rotate.state "$ROTATE_STATE_BACKUP"
fi

active_before=$(cat /run/vision-usb-active 2>/dev/null || true)
if [[ -n "$active_before" ]]; then
  if [[ "$DESTRUCTIVE" == "true" ]]; then
    echo "state=panic" > /run/vision-rotate.state
  else
    echo "state=ok" > /run/vision-rotate.state
  fi
  echo "active=$active_before" >> /run/vision-rotate.state
  echo "reason=test" >> /run/vision-rotate.state
fi

if "$SCRIPT_DIR/../../../scripts/vision-rotator.sh" >/dev/null 2>&1; then
  active_after=$(cat /run/vision-usb-active 2>/dev/null || true)
  if [[ "$DESTRUCTIVE" == "true" ]]; then
    if [[ -n "$active_before" && -n "$active_after" && "$active_before" != "$active_after" ]]; then
      pass "vision-rotator switched LVs: $active_before -> $active_after"
    else
      fail "vision-rotator did not switch LVs in destructive mode"
    fi
    gadget_lun="/sys/kernel/config/usb_gadget/$USB_GADGET_NAME/functions/mass_storage.0/lun.0/file"
    if [[ -f "$gadget_lun" ]]; then
      lun_dev=$(cat "$gadget_lun" || true)
      if [[ -n "$lun_dev" && "$lun_dev" == "$active_after" ]]; then
        pass "gadget LUN points to active LV"
      else
        fail "gadget LUN mismatch: $lun_dev"
      fi
    else
      warn "gadget LUN file missing: $gadget_lun"
    fi
  else
    if [[ "$active_before" == "$active_after" ]]; then
      pass "vision-rotator did not switch LVs (non-destructive)"
    else
      fail "vision-rotator switched LVs in non-destructive mode"
    fi
  fi
else
  fail "vision-rotator script failed"
fi

if [[ -n "$ROTATE_STATE_BACKUP" ]]; then
  cp "$ROTATE_STATE_BACKUP" /run/vision-rotate.state
  rm -f "$ROTATE_STATE_BACKUP"
fi

# NAS checks (optional)
if [[ "${NAS_ENABLED:-false}" == "true" ]]; then
  if systemctl is-enabled --quiet mnt-nas.automount || systemctl is-enabled --quiet mnt-nas.mount; then
    pass "NAS unit enabled"
  else
    warn "NAS unit not enabled"
  fi
  if mountpoint -q "$NAS_MOUNT"; then
    pass "NAS mount active: $NAS_MOUNT"
  else
    warn "NAS mount not active: $NAS_MOUNT"
  fi
  if [[ "$NAS_SYNC" == "true" ]]; then
    if systemctl start nas-sync.service >/dev/null 2>&1; then
      res=$(systemctl show -p Result --value nas-sync.service || true)
      if [[ "$res" == "success" ]]; then
        pass "nas-sync.service ran successfully"
      else
        fail "nas-sync.service result: $res"
      fi
    else
      fail "nas-sync.service failed to start"
    fi
  fi
else
  warn "NAS disabled (NAS_ENABLED=false)"
fi

echo "== Summary =="
echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi

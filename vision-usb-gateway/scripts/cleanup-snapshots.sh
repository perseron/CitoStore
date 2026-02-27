#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config

VG="${LVM_VG:-vg0}"
SNAP_NAME=${SYNC_SNAPSHOT_NAME:-usb_sync_snap}

if command -v lvs >/dev/null 2>&1; then
  if lvs "$VG/$SNAP_NAME" >/dev/null 2>&1; then
    log "stale snapshot detected: $VG/$SNAP_NAME (removing)"
    lvremove -f "$VG/$SNAP_NAME" || true
  fi
fi

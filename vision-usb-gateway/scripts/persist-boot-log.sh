#!/usr/bin/env bash
set -euo pipefail

# Marks the start of a boot in the NVMe journal copy, and clears the empty
# boot-*.log files earlier versions left behind.
#
# This used to save `journalctl -b -1` per boot — but the journal is volatile
# (Storage=volatile under the overlay), so there never is a previous boot to
# read: every boot produced a 0-byte boot-<ts>.log, and the previous boot's
# story was lost. The NVMe copy is kept by journal-persist.sh instead (every few
# minutes, and at clean shutdown via vision-journal-persist-stop.service); this
# just separates the boots inside it.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

: "${MIRROR_MOUNT:=/srv/vision_mirror}"
LOG_DIR="$MIRROR_MOUNT/.state/logs"

if ! mountpoint -q "$MIRROR_MOUNT"; then
  log "mirror not mounted; no boot marker"
  exit 0
fi
mkdir -p "$LOG_DIR"
find "$LOG_DIR" -maxdepth 1 -name 'boot-*.log' -type f -empty -delete 2>/dev/null || true
build=$(grep -m1 '^CITOSTORE_BUILD_SHA=' /etc/citostore-build 2>/dev/null | cut -d= -f2 || true)
printf '\n===== boot %s  %s  build=%s =====\n' \
  "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo '?')" "$(date -Is)" "${build:-?}" \
  >> "$LOG_DIR/journal-current.log"
log "boot marker written to journal-current.log"

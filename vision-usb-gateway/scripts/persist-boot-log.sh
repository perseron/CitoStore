#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

: "${MIRROR_MOUNT:=/srv/vision_mirror}"
LOG_DIR="$MIRROR_MOUNT/.state/logs"
MAX_LOGS=10

mkdir -p "$LOG_DIR" 2>/dev/null || true

# Save previous boot log
ts=$(date +%Y%m%d-%H%M%S)
journalctl -b -1 --no-pager > "$LOG_DIR/boot-${ts}.log" 2>/dev/null || {
  log "no previous boot journal available"
  exit 0
}

log "saved previous boot log to boot-${ts}.log"

# Rotate: keep only MAX_LOGS most recent
count=$(find "$LOG_DIR" -name 'boot-*.log' -type f | wc -l)
if [[ $count -gt $MAX_LOGS ]]; then
  find "$LOG_DIR" -name 'boot-*.log' -type f -printf '%T+ %p\n' | \
    sort | head -n "$((count - MAX_LOGS))" | cut -d' ' -f2- | \
    while IFS= read -r f; do
      rm -f "$f"
      log "removed old boot log: $(basename "$f")"
    done
fi

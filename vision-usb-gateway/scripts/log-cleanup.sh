#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

# Trim journald logs
journalctl --vacuum-size=50M --vacuum-time=7d >/dev/null 2>&1 || true

# Rotate vision-webui.log
: "${MIRROR_MOUNT:=/srv/vision_mirror}"
LOG_FILE="$MIRROR_MOUNT/.state/vision-webui.log"
MAX_SIZE=$((5 * 1024 * 1024))  # 5MB
MAX_ARCHIVES=2

if [[ -f "$LOG_FILE" ]]; then
  size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ $size -ge $MAX_SIZE ]]; then
    # Rotate: remove oldest, shift archives
    for i in $(seq $((MAX_ARCHIVES - 1)) -1 1); do
      next=$((i + 1))
      [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.${next}"
    done
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
    touch "$LOG_FILE"
    log "rotated vision-webui.log"
  fi
fi

log "log cleanup complete"

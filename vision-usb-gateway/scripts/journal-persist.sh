#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

# journald is Storage=volatile (RAM) on the read-only overlay, so a power cut
# loses every log line. This appends the journal tail to the NVMe .state every
# run via a cursor file, so after a power loss at most one timer interval of
# logs is missing. (persist-boot-log only covers graceful reboots.)
: "${MIRROR_MOUNT:=/srv/vision_mirror}"
LOG_DIR="$MIRROR_MOUNT/.state/logs"
OUT="$LOG_DIR/journal-current.log"
CURSOR="$LOG_DIR/journal.cursor"
MAX_SIZE=$((20 * 1024 * 1024))  # 20MB
MAX_ARCHIVES=3

if ! mountpoint -q "$MIRROR_MOUNT"; then
  log "mirror not mounted; skipping journal persist"
  exit 0
fi

mkdir -p "$LOG_DIR"

journalctl --cursor-file="$CURSOR" --no-pager >> "$OUT" 2>/dev/null || true

size=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
if [[ $size -ge $MAX_SIZE ]]; then
  for i in $(seq $((MAX_ARCHIVES - 1)) -1 1); do
    next=$((i + 1))
    [[ -f "${OUT}.${i}" ]] && mv -f "${OUT}.${i}" "${OUT}.${next}"
  done
  mv -f "$OUT" "${OUT}.1"
  touch "$OUT"
  log "rotated journal-current.log"
fi

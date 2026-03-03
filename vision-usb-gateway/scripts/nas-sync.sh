#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

if [[ "${NAS_ENABLED:-false}" != "true" ]]; then
  exit 0
fi

: "${NAS_MOUNT:=/mnt/nas}"
: "${MIRROR_MOUNT:=/srv/vision_mirror}"
: "${NAS_RSYNC_OPTS:=-aH --partial --inplace --timeout=30}"
: "${NAS_RETRY_MAX:=5}"
: "${NAS_RETRY_BACKOFF:=10}"

STATE_DIR="$MIRROR_MOUNT/.state"
NAS_STATUS_FILE="$STATE_DIR/nas-sync-status.json"

write_nas_status() {
  local status="$1" attempts="$2" last_error="${3:-}"
  local ts
  ts=$(date -Is)
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  cat > "$NAS_STATUS_FILE" <<EOF
{"status":"$status","attempts":$attempts,"last_error":"$last_error","last_success_ts":"$ts"}
EOF
}

last_error=""
attempt=1
while [[ $attempt -le $NAS_RETRY_MAX ]]; do
  if timeout 5 ls "$NAS_MOUNT" >/dev/null 2>&1; then
    log "NAS mounted, starting rsync (attempt $attempt)"
    if rsync $NAS_RSYNC_OPTS "$MIRROR_MOUNT/" "$NAS_MOUNT/"; then
      log "NAS sync complete"
      write_nas_status "ok" "$attempt"
      exit 0
    else
      last_error="rsync failed"
    fi
  else
    log "NAS not reachable (attempt $attempt)"
    last_error="NAS not reachable"
  fi
  sleep "$NAS_RETRY_BACKOFF"
  attempt=$((attempt+1))
done

log "NAS sync failed after retries"
write_nas_status "failed" "$NAS_RETRY_MAX" "$last_error"
exit 0

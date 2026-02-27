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

attempt=1
while [[ $attempt -le $NAS_RETRY_MAX ]]; do
  if timeout 5 ls "$NAS_MOUNT" >/dev/null 2>&1; then
    log "NAS mounted, starting rsync (attempt $attempt)"
    if rsync $NAS_RSYNC_OPTS "$MIRROR_MOUNT/" "$NAS_MOUNT/"; then
      log "NAS sync complete"
      exit 0
    fi
  else
    log "NAS not reachable (attempt $attempt)"
  fi
  sleep "$NAS_RETRY_BACKOFF"
  attempt=$((attempt+1))
done

log "NAS sync failed after retries"
exit 0
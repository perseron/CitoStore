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
  # `ls` triggers the automount; only a real share mounted there counts. With
  # the mount down, the path is a plain directory on the RAM root, and rsync
  # copied the whole mirror into RAM.
  if timeout 5 ls "$NAS_MOUNT" >/dev/null 2>&1 \
     && findmnt -n -o FSTYPE -M "$NAS_MOUNT" 2>/dev/null | grep -qvx autofs; then
    log "NAS mounted, starting rsync (attempt $attempt)"
    # Never .state: the session key (admin login forgeable), password hashes,
    # Samba passdb and every credential — on a share others can read, without
    # the 0600 modes — and a torn copy of the live vision.db.
    rc=0
    # shellcheck disable=SC2086  # NAS_RSYNC_OPTS is a list of options
    rsync $NAS_RSYNC_OPTS --exclude=/.state/ "$MIRROR_MOUNT/" "$NAS_MOUNT/" || rc=$?
    # 24 = files vanished during the copy (retention, rotation): normal here.
    if ((rc == 0 || rc == 24)); then
      log "NAS sync complete"
      write_nas_status "ok" "$attempt"
      exit 0
    else
      last_error="rsync failed (rc=$rc)"
    fi
  else
    log "NAS not mounted (attempt $attempt)"
    last_error="NAS not reachable"
  fi
  sleep "$NAS_RETRY_BACKOFF"
  attempt=$((attempt+1))
done

log "NAS sync failed after retries"
write_nas_status "failed" "$NAS_RETRY_MAX" "$last_error"
exit 0

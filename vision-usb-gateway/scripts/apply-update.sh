#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

: "${MIRROR_MOUNT:=/srv/vision_mirror}"
STAGING_DIR="$MIRROR_MOUNT/.state/update-staging"
PERSIST_DIR="$MIRROR_MOUNT/.state/updates"
HISTORY_FILE="$MIRROR_MOUNT/.state/update-history.json"

# MODE can be "apply" (new upload) or "reapply" (boot-time re-application)
MODE="${1:-apply}"

record_history() {
  local ver="$1" status="$2"
  python3 - "$HISTORY_FILE" "$ver" "$status" <<'PY'
import json, sys
from pathlib import Path
from datetime import datetime
path = Path(sys.argv[1])
ver = sys.argv[2]
status = sys.argv[3]
history = []
if path.exists():
    try: history = json.loads(path.read_text())
    except Exception: pass
history.append({"version": ver, "status": status, "ts": datetime.now().isoformat()})
history = history[-20:]
path.write_text(json.dumps(history))
PY
}

if [[ "$MODE" == "reapply" ]]; then
  # Boot-time re-application for overlay mode.
  # Check if root is overlayfs — if not, skip (persistent rootfs keeps changes).
  if ! mount | grep -q 'on / type overlay'; then
    log "not overlay mode; skipping update reapply"
    exit 0
  fi
  if [[ ! -f "$PERSIST_DIR/current.tar.gz" ]]; then
    log "no persisted update to reapply"
    exit 0
  fi
  log "overlay mode detected; reapplying persisted update"
  STAGING_DIR="$PERSIST_DIR/reapply-staging"
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR"
  tar xzf "$PERSIST_DIR/current.tar.gz" -C "$STAGING_DIR" || {
    log "failed to extract persisted update"
    exit 1
  }
fi

if [[ ! -d "$STAGING_DIR" ]]; then
  log "no update staging directory found"
  exit 1
fi

if [[ ! -f "$STAGING_DIR/manifest.json" ]]; then
  log "no manifest.json in update staging"
  exit 1
fi

version=$(python3 -c "
import json; print(json.load(open('$STAGING_DIR/manifest.json'))['version'])
" 2>/dev/null || echo "unknown")

if [[ ! -f "$STAGING_DIR/install.sh" ]]; then
  log "no install.sh in update staging"
  exit 1
fi

log "applying update: $version (mode=$MODE)"

chmod +x "$STAGING_DIR/install.sh"
cd "$STAGING_DIR"
if ! bash install.sh 2>&1 | tee "$STAGING_DIR/install.log"; then
  log "update install.sh failed"
  record_history "$version" "failed"
  exit 1
fi

record_history "$version" "ok"
log "update $version applied successfully"

if [[ "$MODE" == "apply" ]]; then
  # Persist the uploaded archive for boot-time reapply in overlay mode.
  # The WebUI handler keeps update.tar.gz in the staging dir.
  mkdir -p "$PERSIST_DIR"
  if [[ -f "$STAGING_DIR/update.tar.gz" ]]; then
    cp "$STAGING_DIR/update.tar.gz" "$PERSIST_DIR/current.tar.gz"
    log "update archive persisted for overlay reapply"
  else
    # Fallback: re-create archive from staging contents.
    tar czf "$PERSIST_DIR/current.tar.gz" \
      --exclude='install.log' \
      -C "$STAGING_DIR" . || {
      log "warning: failed to persist update archive"
    }
  fi
  # Cleanup staging
  rm -rf "$STAGING_DIR"
elif [[ "$MODE" == "reapply" ]]; then
  rm -rf "$STAGING_DIR"
fi

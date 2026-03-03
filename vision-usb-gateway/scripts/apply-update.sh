#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

: "${MIRROR_MOUNT:=/srv/vision_mirror}"
STAGING_DIR="$MIRROR_MOUNT/.state/update-staging"
HISTORY_FILE="$MIRROR_MOUNT/.state/update-history.json"

if [[ ! -d "$STAGING_DIR" ]]; then
  log "no update staging directory found"
  exit 1
fi

if [[ ! -f "$STAGING_DIR/manifest.json" ]]; then
  log "no manifest.json in update staging"
  exit 1
fi

version=$(python3 -c "import json; print(json.load(open('$STAGING_DIR/manifest.json'))['version'])" 2>/dev/null || echo "unknown")
log "applying update: $version"

if [[ -f "$STAGING_DIR/install.sh" ]]; then
  chmod +x "$STAGING_DIR/install.sh"
  cd "$STAGING_DIR"
  bash install.sh 2>&1 | tee "$STAGING_DIR/install.log" || {
    log "update install.sh failed"
    # Record failure
    python3 - "$HISTORY_FILE" "$version" "failed" <<'PY'
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
    exit 1
  }
fi

# Record success
python3 - "$HISTORY_FILE" "$version" "ok" <<'PY'
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

log "update $version applied successfully"

# Cleanup staging
rm -rf "$STAGING_DIR"

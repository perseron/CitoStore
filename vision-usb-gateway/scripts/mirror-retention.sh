#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config "${CONF_FILE:-}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

: "${MIRROR_MOUNT:=/srv/vision_mirror}"
: "${RETENTION_HI:=90}"
: "${RETENTION_LO:=85}"

usage=$(df -P "$MIRROR_MOUNT" | awk 'NR==2 {print int($5)}' | tr -d '%')
if [[ $usage -lt $RETENTION_HI ]]; then
  exit 0
fi

export MIRROR_MOUNT RETENTION_HI RETENTION_LO DRY_RUN

python3 - <<'PY'
import os
import sqlite3
from pathlib import Path
import shutil

mirror = os.environ.get("MIRROR_MOUNT", "/srv/vision_mirror")
ret_hi = int(os.environ.get("RETENTION_HI", "90"))
ret_lo = int(os.environ.get("RETENTION_LO", "85"))
dry = os.environ.get("DRY_RUN", "false") == "true"

state_db = Path(mirror) / ".state" / "vision.db"
if not state_db.exists():
    raise SystemExit("state DB not found")

def usage_pct():
    total, used, _ = shutil.disk_usage(mirror)
    return int(used * 100 / total)

conn = sqlite3.connect(str(state_db))
conn.row_factory = sqlite3.Row

while usage_pct() >= ret_hi:
    cur = conn.execute("SELECT id, raw_path, bydate_path FROM synced_files ORDER BY synced_at ASC LIMIT 1")
    row = cur.fetchone()
    if row is None:
        break

    raw = Path(row["raw_path"])
    bydate = Path(row["bydate_path"])

    if dry:
        print(f"DRY delete: {raw} and {bydate}")
    else:
        for p in (bydate, raw):
            try:
                p.unlink(missing_ok=True)
            except OSError:
                pass
        conn.execute("DELETE FROM synced_files WHERE id=?", (row["id"],))
        conn.commit()

        d = bydate.parent
        for _ in range(4):
            if d == Path(mirror):
                break
            try:
                d.rmdir()
            except OSError:
                break
            d = d.parent

    if usage_pct() <= ret_lo:
        break

conn.close()
PY

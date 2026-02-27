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
: "${DB_MAINT_INTERVAL_SEC:=86400}"
: "${FILE_STATE_PRUNE_DAYS:=30}"

usage=$(df -P "$MIRROR_MOUNT" | awk 'NR==2 {print int($5)}' | tr -d '%')
if [[ $usage -lt $RETENTION_HI ]]; then
  exit 0
fi

export MIRROR_MOUNT RETENTION_HI RETENTION_LO DRY_RUN DB_MAINT_INTERVAL_SEC FILE_STATE_PRUNE_DAYS

python3 - <<'PY'
import os
import sqlite3
from pathlib import Path
import shutil

mirror = os.environ.get("MIRROR_MOUNT", "/srv/vision_mirror")
ret_hi = int(os.environ.get("RETENTION_HI", "90"))
ret_lo = int(os.environ.get("RETENTION_LO", "85"))
dry = os.environ.get("DRY_RUN", "false") == "true"
db_maint_interval = int(os.environ.get("DB_MAINT_INTERVAL_SEC", "86400"))
file_state_prune_days = int(os.environ.get("FILE_STATE_PRUNE_DAYS", "30"))
now = int(__import__("time").time())

state_db = Path(mirror) / ".state" / "vision.db"
maint_state = Path(mirror) / ".state" / "retention.state.json"
if not state_db.exists():
    raise SystemExit("state DB not found")

def usage_pct():
    total, used, _ = shutil.disk_usage(mirror)
    return int(used * 100 / total)

def remove_empty_ancestors(path: Path, stop: Path) -> None:
    d = path.parent
    for _ in range(8):
        if d == stop:
            break
        try:
            d.rmdir()
        except OSError:
            break
        d = d.parent

def load_maint_state() -> dict:
    if not maint_state.exists():
        return {}
    try:
        import json
        return json.loads(maint_state.read_text(encoding="utf-8"))
    except Exception:
        return {}

def save_maint_state(data: dict) -> None:
    try:
        import json
        maint_state.parent.mkdir(parents=True, exist_ok=True)
        maint_state.write_text(json.dumps(data), encoding="utf-8")
    except Exception:
        pass

def file_fallback_delete_one() -> bool:
    raw_root = Path(mirror) / "raw"
    bydate_root = Path(mirror) / "bydate"
    if not raw_root.exists():
        return False

    inode_links: dict[tuple[int, int], list[Path]] = {}
    if bydate_root.exists():
        for p in bydate_root.rglob("*"):
            if not p.is_file():
                continue
            try:
                st = p.stat()
            except OSError:
                continue
            inode_links.setdefault((st.st_dev, st.st_ino), []).append(p)

    candidates: list[tuple[float, Path, tuple[int, int]]] = []
    for p in raw_root.rglob("*"):
        if not p.is_file():
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        candidates.append((st.st_mtime, p, (st.st_dev, st.st_ino)))
    candidates.sort(key=lambda x: x[0])

    for _, raw_path, inode in candidates:
        if dry:
            print(f"DRY fallback delete: {raw_path}")
            return True
        try:
            raw_path.unlink(missing_ok=True)
        except OSError:
            continue
        for link in inode_links.get(inode, []):
            try:
                link.unlink(missing_ok=True)
            except OSError:
                pass
            remove_empty_ancestors(link, bydate_root)
        remove_empty_ancestors(raw_path, raw_root)
        return True
    return False

conn = sqlite3.connect(str(state_db))
conn.row_factory = sqlite3.Row

if not dry:
    # Remove rows where both paths are already gone.
    cur = conn.execute("SELECT id, raw_path, bydate_path FROM synced_files")
    stale_ids = []
    for row in cur.fetchall():
        raw = Path(row["raw_path"]) if row["raw_path"] else None
        bydate = Path(row["bydate_path"]) if row["bydate_path"] else None
        raw_exists = bool(raw and raw.exists())
        bydate_exists = bool(bydate and bydate.exists())
        if not raw_exists and not bydate_exists:
            stale_ids.append(row["id"])
    if stale_ids:
        conn.executemany("DELETE FROM synced_files WHERE id=?", [(i,) for i in stale_ids])
        conn.commit()

    # Prune old file_state entries to keep DB bounded.
    ttl = max(1, file_state_prune_days) * 86400
    cutoff = now - ttl
    conn.execute("DELETE FROM file_state WHERE last_seen < ?", (cutoff,))
    conn.commit()

progress_failures = 0
while usage_pct() >= ret_hi:
    before = usage_pct()
    cur = conn.execute("SELECT id, raw_path, bydate_path FROM synced_files ORDER BY synced_at ASC LIMIT 1")
    row = cur.fetchone()
    if row is None:
        if not file_fallback_delete_one():
            break
        progress_failures = 0
        if usage_pct() <= ret_lo:
            break
        continue

    raw = Path(row["raw_path"]) if row["raw_path"] else None
    bydate = Path(row["bydate_path"]) if row["bydate_path"] else None

    if dry:
        print(f"DRY delete: {raw} and {bydate}")
    else:
        for p in (bydate, raw):
            if p is None:
                continue
            try:
                p.unlink(missing_ok=True)
            except OSError:
                pass
        conn.execute("DELETE FROM synced_files WHERE id=?", (row["id"],))
        conn.commit()
        if bydate is not None:
            remove_empty_ancestors(bydate, Path(mirror) / "bydate")

    if usage_pct() <= ret_lo:
        break

    after = usage_pct()
    if after >= before:
        progress_failures += 1
    else:
        progress_failures = 0

    # DB says we deleted, but usage didn't move; use file fallback.
    if progress_failures >= 3:
        if file_fallback_delete_one():
            progress_failures = 0
        else:
            break

if not dry and db_maint_interval > 0:
    state = load_maint_state()
    last_vacuum_ts = int(state.get("last_vacuum_ts", 0) or 0)
    if now - last_vacuum_ts >= db_maint_interval:
        try:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            conn.execute("VACUUM")
            save_maint_state({"last_vacuum_ts": now})
        except Exception:
            pass

conn.close()
PY

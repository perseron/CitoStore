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
# FTP/SFTP ingest data (not DB-tracked) is retained by oldest-file deletion too.
: "${INGEST_DIR:=$MIRROR_MOUNT/ingest}"
# Keep the synced_files identity row this long after its mirror copy is
# reclaimed, so a file still on the active USB LV is not re-copied (NVMe churn).
# Must exceed the worst-case USB LV residency; prune only bounds the DB.
: "${RETENTION_ROW_TTL_DAYS:=90}"

# Gate on the SAME used/total ratio the Python delete-loop below uses
# (shutil.disk_usage). df -P's Use% excludes the ext4 root-reserved blocks, so
# it reads ~5% higher than shutil; using it here let retention "trigger" in a
# 90–95% band where the loop's shutil check was still < HI and deleted nothing.
usage=$(python3 -c "import shutil; t,u,_=shutil.disk_usage('$MIRROR_MOUNT'); print(int(u*100/t))")
if [[ $usage -lt $RETENTION_HI ]]; then
  exit 0
fi

export MIRROR_MOUNT RETENTION_HI RETENTION_LO DRY_RUN DB_MAINT_INTERVAL_SEC FILE_STATE_PRUNE_DAYS
export RETENTION_ROW_TTL_DAYS INGEST_DIR

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
row_ttl_days = int(os.environ.get("RETENTION_ROW_TTL_DAYS", "90"))
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
    # FTP/SFTP ingest data lives here and is not tracked in the DB.
    ingest_data = Path(os.environ.get("INGEST_DIR", str(Path(mirror) / "ingest"))) / "data"
    prune_roots = [r for r in (raw_root, ingest_data) if r.exists()]
    if not prune_roots:
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
    for root in prune_roots:
        for p in root.rglob("*"):
            if not p.is_file():
                continue
            try:
                st = p.stat()
            except OSError:
                continue
            candidates.append((st.st_mtime, p, (st.st_dev, st.st_ino), root))
    candidates.sort(key=lambda x: x[0])

    for _, raw_path, inode, root in candidates:
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
        remove_empty_ancestors(raw_path, root)
        return True
    return False

conn = sqlite3.connect(str(state_db))
conn.row_factory = sqlite3.Row

if not dry:
    # Prune synced_files rows by age (bounds the DB). Rows are intentionally
    # kept even after their mirror copy is reclaimed below, so a file still on
    # the active USB LV is not re-copied (is_already_synced stays true). A row
    # older than the TTL has surely rotated away, so dropping it is safe.
    row_ttl = max(1, row_ttl_days) * 86400
    conn.execute("DELETE FROM synced_files WHERE synced_at < ?", (now - row_ttl,))
    conn.commit()

    # Prune old file_state entries to keep DB bounded.
    ttl = max(1, file_state_prune_days) * 86400
    conn.execute("DELETE FROM file_state WHERE last_seen < ?", (now - ttl,))
    conn.commit()

progress_failures = 0
while usage_pct() >= ret_hi:
    before = usage_pct()
    cur = conn.execute(
        "SELECT id, raw_path, bydate_path FROM synced_files "
        "WHERE raw_path != '' OR bydate_path != '' "
        "ORDER BY synced_at ASC LIMIT 1"
    )
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
        # Keep the identity row (blank its paths) so the same file still on the
        # active USB LV is not re-synced back into the mirror; age-prune clears
        # it later. This is what stops the retention<->sync re-copy churn.
        conn.execute(
            "UPDATE synced_files SET raw_path='', bydate_path='' WHERE id=?",
            (row["id"],),
        )
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

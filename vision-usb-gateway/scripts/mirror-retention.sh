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
  # Back at the target by other means (something unprotected, deleted by
  # hand): the "cannot free space" alarm is over.
  if [[ $usage -le $RETENTION_LO ]]; then
    rm -f "$MIRROR_MOUNT/.state/retention-blocked.json"
  fi
  # Once a day the empty-folder sweep runs anyway (nothing deleted).
  stamp="$MIRROR_MOUNT/.state/retention-sweep.stamp"
  if [[ -f "$stamp" && -z "$(find "$stamp" -mmin +1440 2>/dev/null)" ]]; then
    exit 0
  fi
  SWEEP_ONLY=true
fi
export SWEEP_ONLY="${SWEEP_ONLY:-false}"

# SQLite's temporary files (VACUUM, index builds) on the NVMe: the service's
# /tmp is the RAM root, and a DB of millions of rows needed more than a 2 GB
# unit has. (SQLite deletes them as soon as it opens them.)
export SQLITE_TMPDIR="$MIRROR_MOUNT/.state/tmp"
mkdir -p "$SQLITE_TMPDIR"
export MIRROR_MOUNT RETENTION_HI RETENTION_LO DRY_RUN DB_MAINT_INTERVAL_SEC FILE_STATE_PRUNE_DAYS
export RETENTION_ROW_TTL_DAYS INGEST_DIR

python3 - <<'PY'
import os
import sqlite3
from pathlib import Path
import shutil
import heapq

mirror = os.environ.get("MIRROR_MOUNT", "/srv/vision_mirror")
ret_hi = int(os.environ.get("RETENTION_HI", "90"))
ret_lo = int(os.environ.get("RETENTION_LO", "85"))
dry = os.environ.get("DRY_RUN", "false") == "true"
# The daily empty-folder sweep alone (the bash gate: usage below HI).
sweep_only = os.environ.get("SWEEP_ONLY", "false") == "true"
db_maint_interval = int(os.environ.get("DB_MAINT_INTERVAL_SEC", "86400"))
file_state_prune_days = int(os.environ.get("FILE_STATE_PRUNE_DAYS", "30"))
row_ttl_days = int(os.environ.get("RETENTION_ROW_TTL_DAYS", "90"))
now = int(__import__("time").time())

state_db = Path(mirror) / ".state" / "vision.db"
maint_state = Path(mirror) / ".state" / "retention.state.json"
# Folders an operator marked keep-forever, chosen in the WebUI. Lives on the NVMe
# so it survives an OS reflash — protection quietly lapsing after an update would
# be worse than never having offered it.
protected_file = Path(mirror) / ".state" / "retention-protected.json"
if not state_db.exists():
    raise SystemExit("state DB not found")

def load_protected() -> list:
    """Absolute, resolved roots that must never be deleted.

    Fail closed: if the list cannot be read, protect nothing is the wrong answer
    — but so is deleting everything on a parse error. Raise instead, so the run
    aborts loudly and a broken file cannot silently un-protect an operator's data.
    """
    if not protected_file.exists():
        return []
    import json
    raw = json.loads(protected_file.read_text(encoding="utf-8"))
    roots = []
    base = Path(mirror).resolve()
    for rel in raw.get("paths", []):
        p = (base / str(rel).lstrip("/")).resolve()
        if p == base or base not in p.parents:
            continue  # never let a bad entry protect (or escape) the whole mirror
        roots.append(p)
    return roots

protected = load_protected()

def usage_pct():
    total, used, _ = shutil.disk_usage(mirror)
    return int(used * 100 / total)

def remove_empty_ancestors(path: Path, stop: Path) -> None:
    d = path.parent
    while d != stop and stop in d.parents:
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

# timeout/busy_timeout: the sync holds the DB write lock for a whole cycle, an
# LV export for minutes; with sqlite3's default 5 s retention failed then.
conn = sqlite3.connect(str(state_db), timeout=60)
conn.row_factory = sqlite3.Row
conn.execute("PRAGMA busy_timeout=60000")
# One raw_path lookup per deleted file (to find its bydate link).
conn.execute("CREATE INDEX IF NOT EXISTS idx_synced_raw ON synced_files(raw_path)")
conn.commit()

if not dry:
    # Prune synced_files rows by age (bounds the DB) — only rows whose files
    # retention already reclaimed (blanked); they are kept that long so a file
    # still on the active USB LV is not re-copied. The prune used to drop rows
    # of files still on the mirror (on a mirror holding over 90 days), and
    # every clock correction after a dead RTC aged rows at once.
    row_ttl = max(1, row_ttl_days) * 86400
    conn.execute(
        "DELETE FROM synced_files WHERE synced_at < ? AND raw_path = '' AND bydate_path = ''",
        (now - row_ttl,),
    )
    conn.commit()

    # Prune old file_state entries to keep DB bounded.
    ttl = max(1, file_state_prune_days) * 86400
    conn.execute("DELETE FROM file_state WHERE last_seen < ?", (now - ttl,))
    conn.commit()

base = Path(mirror).resolve()
raw_root = base / "raw"
bydate_root = base / "bydate"
# FTP/SFTP ingest data lives here and is not tracked in the DB.
ingest_data = Path(os.environ.get("INGEST_DIR", str(base / "ingest"))).resolve() / "data"
protected_strs = [str(r) for r in protected]


def under_protected(path: str) -> bool:
    # Walked paths are real (from the resolved mirror, links never followed),
    # so a string prefix is exact — no per-file resolve().
    return any(path == r or path.startswith(r + "/") for r in protected_strs)


def walk_files(root: Path, visit) -> None:
    """visit(path, stat) for every regular file under root that is not
    protected; links are never followed, protected trees not even entered."""
    stack = [str(root)]
    while stack:
        d = stack.pop()
        if under_protected(d):
            continue
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                    elif e.is_file(follow_symlinks=False) and not under_protected(e.path):
                        visit(e.path, e.stat(follow_symlinks=False))
                except OSError:
                    continue


def arrival(st, root: Path) -> float:
    """When a file arrived on the mirror. raw/ and bydate/: its mtime — the
    sync never copies the drive's timestamps, so it is the copy's own time,
    and a chown leaves it alone: versions before 64b62cb chown -R'd raw/ and
    bydate/ on every boot and Save + Apply, so on a unit updated from them
    every file's ctime is that of its last old boot. ingest/data: its ctime —
    an FTP client may set the mtime (MDTM, the AOI's clock: a PC set to 2030
    would have kept its files forever), and nothing ever chown'd those."""
    return st.st_ctime if root == ingest_data else st.st_mtime


def scan(root: Path, only_single_link: bool = False) -> list:
    """(arrival, path, inode, nlink) of the files under root (walk_files)."""
    out = []

    def visit(path, st):
        if only_single_link and st.st_nlink != 1:
            return
        out.append((arrival(st, root), path, st.st_ino, st.st_nlink))

    walk_files(root, visit)
    return out


def oldest_files(roots: list, want: float) -> list:
    """The fewest oldest files (by arrival) whose space adds up to `want`
    bytes, as (arrival, path, inode, nlink, root) — one walk, through a
    heap that drops the newest as soon as the rest cover `want`. Listing every
    file cost ~350 MB of RAM per million (measured): a mirror of small images
    holds several million, more than a 2 GB unit can spare."""
    heap: list = []  # (-arrival, bytes, path, inode, nlink, root index)
    kept = 0

    for k, root in enumerate(roots):
        def visit(path, st, k=k):
            nonlocal kept
            t = arrival(st, roots[k])
            if kept >= want and heap and t >= -heap[0][0]:
                return  # newer than every file already enough
            size = st.st_blocks * 512
            heapq.heappush(heap, (-t, size, path, st.st_ino, st.st_nlink, k))
            kept += size
            while heap and kept - heap[0][1] >= want:
                kept -= heapq.heappop(heap)[1]

        walk_files(root, visit)
    return [(-c, path, ino, nlink, roots[k]) for c, _, path, ino, nlink, k in heap]


def sweep_empty_dirs(root: Path, min_age: int) -> int:
    """Remove folders that have been empty for `min_age` seconds — left by
    older versions (they never removed the raw/ folders they emptied) or
    created and never used. One level per run: a parent emptied now has a
    fresh mtime, so nested empty trees go over the following days. Files are
    not stat'ed (d_type): a cheap walk."""
    removed = 0
    now_ts = __import__("time").time()
    stack = [str(root)]
    while stack:
        d = stack.pop()
        if under_protected(d):
            continue
        try:
            with os.scandir(d) as it:
                entries = list(it)
        except OSError:
            continue
        if not entries:
            if d != str(root):
                try:
                    if now_ts - os.lstat(d).st_mtime >= min_age:
                        os.rmdir(d)
                        removed += 1
                except OSError:
                    pass
            continue
        for e in entries:
            try:
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
            except OSError:
                continue
    return removed


_bydate_links = None


def bydate_links(ino: int) -> list:
    """bydate paths of an inode, for files the DB cannot place (DB lost,
    rows from an older version). Built once, only if ever needed."""
    global _bydate_links
    if _bydate_links is None:
        _bydate_links = {}
        if bydate_root.exists():
            for _, p, i, n in scan(bydate_root):
                if n > 1:
                    _bydate_links.setdefault(i, []).append(p)
    return _bydate_links.get(ino, [])


pending_blank = []
unlink_failed = {"inodes": set(), "first": ""}  # once per file, not per round


def flush_blanks() -> None:
    # Keep the identity rows (blank their paths, not delete) so a file still on
    # the active USB LV is not re-synced back into the mirror; the TTL prune
    # above clears them later. One executemany+commit per batch.
    if pending_blank and not dry:
        conn.executemany(
            "UPDATE synced_files SET raw_path='', bydate_path='' WHERE id=?",
            [(i,) for i in pending_blank],
        )
        conn.commit()
    pending_blank.clear()


def delete(path: str, ino: int, nlink: int, root: Path) -> bool:
    """Delete one file and every bydate link of it — the space comes back only
    when the last link goes. False if one of its links is protected."""
    rows = conn.execute(
        "SELECT id, bydate_path FROM synced_files WHERE raw_path = ?", (path,)
    ).fetchall()
    links = []
    for row in rows:
        bp = row["bydate_path"]
        if bp and bp != path:
            try:
                if os.lstat(bp).st_ino == ino:
                    links.append(bp)
            except OSError:
                pass
    if nlink > 1 + len(links):
        links = sorted(set(links) | {p for p in bydate_links(ino) if p != path})
    # Protection is about the data, not a path: one protected link keeps it.
    if any(under_protected(p) for p in links):
        return False
    if dry:
        print(f"DRY delete: {path} {links}")
        return True
    for p, stop in [(path, root)] + [(p, bydate_root) for p in links]:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
        except OSError as exc:
            # Counted, not swallowed: a delete refused (EACCES) left files that
            # only looked "kept on purpose" in the blocked alarm.
            unlink_failed["inodes"].add(ino)
            unlink_failed["first"] = unlink_failed["first"] or f"{p}: {exc.strerror}"
        # Not in ingest/data: those folders are the Ethernet AOI's, which may
        # upload into a fixed one it does not recreate (as for the sweep).
        if stop != ingest_data:
            remove_empty_ancestors(Path(p), stop)
    pending_blank.extend(row["id"] for row in rows)
    if len(pending_blank) >= 500:
        flush_blanks()
    return True


def free_space(candidates: list) -> None:
    """Oldest first until usage is back at RETENTION_LO."""
    candidates.sort()
    shown = 0
    for _, path, ino, nlink, root in candidates:
        if not dry and usage_pct() <= ret_lo:  # statvfs: one cheap syscall
            return
        if delete(path, ino, nlink, root) and dry:
            shown += 1
            if shown >= 20:
                return


# Folders left empty, in the trees this unit builds itself (raw/, bydate/):
# once they have been empty for a day. Not ingest/data — that structure is the
# Ethernet AOI's, which may expect a folder it made to still be there.
EMPTY_DIR_MIN_AGE = 86400
if not dry:
    swept = sum(sweep_empty_dirs(r, EMPTY_DIR_MIN_AGE) for r in (raw_root, bydate_root) if r.exists())
    if swept:
        print(f"retention: removed {swept} empty folder(s)", flush=True)
    try:
        (Path(mirror) / ".state" / "retention-sweep.stamp").touch()
    except OSError:
        pass

# We are here only because the bash gate above saw usage >= RETENTION_HI (or
# for the daily empty-folder sweep alone). Oldest-first deletion down to
# RETENTION_LO, in arrival order across everything:
# - by arrival on the mirror (arrival(): never the AOI's clock)
# - USB images (raw/, with their bydate links) and the Ethernet AOI's files
#   (ingest/data, never in the DB) interleaved — before, ingest data went only
#   after every USB image, down to minutes-old ones;
# - files the DB no longer knows (a lost/corrupt vision.db, rows an older
#   version pruned while the files were still there) in their place by age —
#   before, they could only go once the DB had nothing left, so the NEWEST
#   images were deleted while the oldest stayed;
# - protected folders skipped in the walk itself. The old DB loop re-selected
#   the same protected rows forever and then deleted ONE file per walk of the
#   whole tree: K deletions cost K full walks, and a run freed a few hundred
#   files in its 30 minutes while the mirror filled.
# Listed: only the oldest files that cover what must go (+25%; oldest_files).
# Short (files protected through a bydate link, files changed meanwhile):
# wider, then all.
roots = [r for r in (raw_root, ingest_data) if r.exists()]
if not sweep_only:
    for factor in (1.25, 2.5, 5, None):
        total, used, _ = shutil.disk_usage(mirror)
        need = max(used - total * ret_lo // 100, 1 if dry else 0)
        if need <= 0:
            break
        want = float("inf") if factor is None else int(need * factor) + (64 << 20)
        candidates = oldest_files(roots, want)
        print(
            f"retention: {len(candidates)} oldest files listed, usage {usage_pct()}% -> target {ret_lo}%",
            flush=True,
        )
        free_space(candidates)
        del candidates
        if dry or usage_pct() <= ret_lo or factor is None:
            break
    # Last: bydate links whose raw copy is already gone (single link left).
    if dry or usage_pct() > ret_lo:
        if bydate_root.exists():
            free_space([(c, p, i, n, bydate_root) for c, p, i, n in scan(bydate_root, only_single_link=True)])
    flush_blanks()
    if unlink_failed["inodes"]:
        print(
            f"retention: {len(unlink_failed['inodes'])} file(s) could not be deleted, first: {unlink_failed['first']}",
            flush=True,
        )


# Protection holds: protected data is never deleted to make room. But retention
# giving up quietly is how the mirror fills, the sync's free-space guard trips,
# and the AOI's images stop being captured while everything still looks green.
# Say so loudly enough that it is noticed before that happens.
final = usage_pct()
# Could not get back to RETENTION_LO: everything it may delete is gone and
# what is left is kept on purpose — protected folders, or the AOI's settings
# folder. Recorded for the health banner (vision-monitor: retention_blocked_
# issues) the first time it happens, well before the mirror is full; it used
# to be written only at >= HI and with protection, and shown only on the
# /protected page. When the mirror does fill, USB drives are recycled
# without their images.
blocked_file = Path(mirror) / ".state" / "retention-blocked.json"
if sweep_only:
    pass
elif not dry and final > ret_lo:
    import json
    try:
        tmp = blocked_file.with_name(blocked_file.name + ".tmp")
        tmp.write_text(
            json.dumps({"usage": final, "target": ret_lo, "protected": len(protected),
                        "undeletable": len(unlink_failed["inodes"]), "ts": now}),
            encoding="utf-8",
        )
        tmp.replace(blocked_file)
    except OSError:
        pass
    print(
        f"CRITICAL: mirror at {final}% and retention cannot reach {ret_lo}% — "
        + (f"{len(unlink_failed['inodes'])} file(s) could not be deleted. " if unlink_failed["inodes"] else
           f"{len(protected)} protected folder(s) are keeping the rest. " if protected else
           "nothing it may delete is left. ")
        + "When the mirror fills, USB drives are recycled without their images.",
        flush=True,
    )
elif not dry:
    try:
        blocked_file.unlink(missing_ok=True)
    except OSError:
        pass

if not dry and db_maint_interval > 0:
    state = load_maint_state()
    last_vacuum_ts = int(state.get("last_vacuum_ts", 0) or 0)
    if now - last_vacuum_ts >= db_maint_interval:
        try:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            # VACUUM rewrites the whole DB (rows of every image on the mirror:
            # ~340 MB per million) through a temporary copy — only when a
            # quarter of it is free pages, and never in /tmp (RAM on this unit;
            # SQLITE_TMPDIR points at the NVMe, see the bash part).
            pages = conn.execute("PRAGMA page_count").fetchone()[0]
            free = conn.execute("PRAGMA freelist_count").fetchone()[0]
            if pages and free * 4 >= pages:
                conn.execute("VACUUM")
            save_maint_state({"last_vacuum_ts": now})
        except Exception:
            pass

conn.close()
PY

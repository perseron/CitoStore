import sqlite3
from pathlib import Path


def init_db(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    # Sync, retention, and an offline-maint export can all touch this DB
    # around the same moment (a rotation firing while retention is mid-run).
    # WAL allows concurrent readers, but writers can still collide briefly;
    # without this, sqlite3's default 0ms busy timeout throws
    # "database is locked" immediately instead of waiting the brief moment
    # the other writer actually needs (observed live: a retention run
    # crashed outright this way).
    conn.execute("PRAGMA busy_timeout=30000")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS file_state (
            path TEXT PRIMARY KEY,
            size INTEGER,
            mtime INTEGER,
            stable_count INTEGER,
            last_seen INTEGER
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS synced_files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_path TEXT,
            size INTEGER,
            mtime INTEGER,
            raw_path TEXT,
            bydate_path TEXT,
            synced_at INTEGER
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_file_state_last_seen ON file_state(last_seen)")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_synced_lookup ON synced_files(source_path, size, mtime)"
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_synced_at ON synced_files(synced_at)")
    # Retention's oldest-first scan (mirror-retention.sh) filters on
    # "raw_path != '' OR bydate_path != ''" -- rows already reclaimed by a
    # PREVIOUS retention run are kept (blanked, not deleted) until the
    # 90-day row TTL, so they pile up at the head of the synced_at order.
    # The plain idx_synced_at index still makes retention walk past that
    # entire (ever-growing) blanked prefix on EVERY single per-file
    # deletion, since the WHERE clause isn't part of that index -- fine at
    # small scale, but a live run degraded from sub-second to a 30-minute
    # systemd timeout as the prefix grew over a week of testing. A partial
    # index covering exactly this predicate lets SQLite jump straight to
    # the live rows instead of scanning past the dead ones every time.
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_synced_at_live ON synced_files(synced_at)"
        " WHERE raw_path != '' OR bydate_path != ''"
    )
    # Retention looks each deleted file up by its mirror path (its bydate link).
    conn.execute("CREATE INDEX IF NOT EXISTS idx_synced_raw ON synced_files(raw_path)")
    conn.commit()
    return conn


def update_state(conn: sqlite3.Connection, path: str, size: int, mtime: int, now: int) -> int:
    cur = conn.execute("SELECT size, mtime, stable_count FROM file_state WHERE path=?", (path,))
    row = cur.fetchone()
    if row is None:
        stable = 1
        conn.execute(
            "INSERT INTO file_state (path, size, mtime, stable_count, last_seen)"
            " VALUES (?, ?, ?, ?, ?)",
            (path, size, mtime, stable, now),
        )
    else:
        prev_size, prev_mtime, prev_stable = row
        stable = prev_stable + 1 if prev_size == size and prev_mtime == mtime else 1
        conn.execute(
            "UPDATE file_state SET size=?, mtime=?, stable_count=?, last_seen=? WHERE path=?",
            (size, mtime, stable, now, path),
        )
    return stable


def is_already_synced(conn: sqlite3.Connection, path: str, size: int, mtime: int) -> bool:
    cur = conn.execute(
        "SELECT 1 FROM synced_files WHERE source_path=? AND size=? AND mtime=? LIMIT 1",
        (path, size, mtime),
    )
    return cur.fetchone() is not None


def mark_synced(
    conn: sqlite3.Connection,
    source_path: str,
    size: int,
    mtime: int,
    raw_path: str,
    bydate_path: str,
    now: int,
) -> None:
    conn.execute(
        "INSERT INTO synced_files"
        " (source_path, size, mtime, raw_path, bydate_path, synced_at)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        (source_path, size, mtime, raw_path, bydate_path, now),
    )

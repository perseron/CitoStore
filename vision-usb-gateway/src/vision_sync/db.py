import sqlite3
from pathlib import Path


def init_db(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
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
    conn.commit()
    return conn


def update_state(conn: sqlite3.Connection, path: str, size: int, mtime: int, now: int) -> int:
    cur = conn.execute("SELECT size, mtime, stable_count FROM file_state WHERE path=?", (path,))
    row = cur.fetchone()
    if row is None:
        stable = 1
        conn.execute(
            "INSERT INTO file_state (path, size, mtime, stable_count, last_seen) VALUES (?, ?, ?, ?, ?)",
            (path, size, mtime, stable, now),
        )
    else:
        prev_size, prev_mtime, prev_stable = row
        if prev_size == size and prev_mtime == mtime:
            stable = prev_stable + 1
        else:
            stable = 1
        conn.execute(
            "UPDATE file_state SET size=?, mtime=?, stable_count=?, last_seen=? WHERE path=?",
            (size, mtime, stable, now, path),
        )
    conn.commit()
    return stable


def is_already_synced(conn: sqlite3.Connection, path: str, size: int, mtime: int) -> bool:
    cur = conn.execute(
        "SELECT 1 FROM synced_files WHERE source_path=? AND size=? AND mtime=? LIMIT 1",
        (path, size, mtime),
    )
    return cur.fetchone() is not None


def mark_synced(conn: sqlite3.Connection, source_path: str, size: int, mtime: int, raw_path: str, bydate_path: str, now: int) -> None:
    conn.execute(
        "INSERT INTO synced_files (source_path, size, mtime, raw_path, bydate_path, synced_at) VALUES (?, ?, ?, ?, ?, ?)",
        (source_path, size, mtime, raw_path, bydate_path, now),
    )
    conn.commit()
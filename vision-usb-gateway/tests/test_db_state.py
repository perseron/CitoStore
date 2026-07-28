from pathlib import Path

from vision_sync.db import init_db, is_already_synced, mark_synced


def test_db_state(tmp_path: Path):
    db = tmp_path / "vision.db"
    conn = init_db(db)

    assert not is_already_synced(conn, "a.jpg", 1, 2)
    mark_synced(conn, "a.jpg", 1, 2, "/raw/a", "/bydate/a", 3)
    assert is_already_synced(conn, "a.jpg", 1, 2)


def test_busy_timeout_set_so_concurrent_writers_wait_not_crash(tmp_path: Path):
    """Regression: sqlite3's default busy timeout is 0 -- a retention run
    collided with a concurrent sync/offline-maint write and crashed outright
    with "database is locked" instead of waiting the brief moment the other
    writer actually needed."""
    conn = init_db(tmp_path / "vision.db")
    (timeout_ms,) = conn.execute("PRAGMA busy_timeout").fetchone()
    assert timeout_ms > 0


def test_retention_oldest_first_scan_uses_the_live_partial_index(tmp_path: Path):
    """Regression: mirror-retention.sh's oldest-first query re-runs on EVERY
    single file it deletes. Rows already reclaimed by an earlier retention
    run are kept (blanked, not deleted) until the 90-day row TTL, so without
    an index covering the "still has a copy" predicate, each of those
    per-file queries re-scans the entire, ever-growing blanked prefix via
    idx_synced_at -- a live run degraded from sub-second to a 30-minute
    systemd timeout as that prefix grew over a week of testing. The query
    plan must show SQLite using the partial index, not idx_synced_at (which
    would mean it's walking the dead rows) or a full table scan."""
    conn = init_db(tmp_path / "vision.db")
    plan = conn.execute(
        "EXPLAIN QUERY PLAN "
        "SELECT id, raw_path, bydate_path FROM synced_files "
        "WHERE raw_path != '' OR bydate_path != '' "
        "ORDER BY synced_at ASC LIMIT 200"
    ).fetchall()
    detail = " ".join(row[-1] for row in plan)
    assert "idx_synced_at_live" in detail, f"expected the partial index in the plan, got: {detail}"

import os
from pathlib import Path
from types import SimpleNamespace

from vision_sync.db import init_db
from vision_sync.sync import select_scan_roots, stable_and_copy


def _sync_cfg(mirror: Path, tmp_path: Path, depth: int) -> SimpleNamespace:
    return SimpleNamespace(
        mirror_mount=mirror,
        state_dir=mirror / ".state",
        mirror_free_min_mb=0,
        mirror_retention_trigger_pct=101,
        max_file_size=4 * 1024**3,
        stable_scans=1,
        copy_chunk=1 << 20,
        append_always=False,
        bydate_use_file_time=False,
        sync_log_every=0,
        sync_scan_depth=depth,
        sync_hot_dirs=8,
        sync_cold_audit_dirs_per_run=8,
        sync_dir_index_file=tmp_path / "idx.json",
    )


def _synced_paths(conn) -> list[str]:
    rows = conn.execute("SELECT source_path FROM synced_files").fetchall()
    return sorted(Path(r[0]).as_posix() for r in rows)


def _touch_dir(path: Path, ts: int) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.utime(path, (ts, ts))


def test_select_scan_roots_hot_plus_round_robin(tmp_path: Path):
    root = tmp_path / "snap"
    root.mkdir()

    _touch_dir(root / "old", 100)
    _touch_dir(root / "mid", 200)
    _touch_dir(root / "new", 300)

    cfg = SimpleNamespace(
        sync_scan_depth=1,
        sync_hot_dirs=1,
        sync_cold_audit_dirs_per_run=1,
        sync_dir_index_file=tmp_path / "sync-dir-index.json",
    )

    roots_1, plan_1 = select_scan_roots(cfg, root)
    assert [p.name for p in roots_1] == ["new", "mid"]
    assert plan_1["hot"] == ["new"]
    assert plan_1["audit"] == ["mid"]

    roots_2, plan_2 = select_scan_roots(cfg, root)
    assert [p.name for p in roots_2] == ["new", "old"]
    assert plan_2["hot"] == ["new"]
    assert plan_2["audit"] == ["old"]


def test_select_scan_roots_uses_depth_and_skips_system_dirs(tmp_path: Path):
    root = tmp_path / "snap"
    root.mkdir()

    _touch_dir(root / "cv-x" / "image" / "SD1_000" / "session_new", 500)
    _touch_dir(root / "cv-x" / "image" / "SD1_000" / "session_old", 400)
    _touch_dir(root / "System Volume Information", 999)

    cfg = SimpleNamespace(
        sync_scan_depth=4,
        sync_hot_dirs=1,
        sync_cold_audit_dirs_per_run=1,
        sync_dir_index_file=tmp_path / "sync-dir-index-depth.json",
    )

    roots, plan = select_scan_roots(cfg, root)
    assert plan["depth"] == 4
    assert [p.as_posix() for p in roots] == [
        (root / "cv-x/image/SD1_000/session_new").as_posix(),
        (root / "cv-x/image/SD1_000/session_old").as_posix(),
    ]
    # Every level above SYNC_SCAN_DEPTH must still be scanned non-recursively.
    assert plan["shallow"] == ["cv-x", "cv-x/image", "cv-x/image/SD1_000"]


def test_files_above_scan_depth_are_not_skipped(tmp_path: Path):
    """Regression: with SYNC_SCAN_DEPTH>1 intermediate files were silently lost."""
    root = tmp_path / "snap"
    session = root / "cv-x" / "image" / "SD1_000" / "session_new"
    session.mkdir(parents=True)

    (root / "rootfile.jpg").write_bytes(b"a")
    (root / "cv-x" / "top.jpg").write_bytes(b"b")
    (root / "cv-x" / "image" / "SD1_000" / "mid.jpg").write_bytes(b"c")
    (session / "deep.jpg").write_bytes(b"d")

    mirror = tmp_path / "mirror"
    conn = init_db(mirror / ".state" / "vision.db")
    try:
        stable_and_copy(_sync_cfg(mirror, tmp_path, depth=4), root, conn)
        got = _synced_paths(conn)
    finally:
        conn.close()

    assert got == [
        "cv-x/image/SD1_000/mid.jpg",
        "cv-x/image/SD1_000/session_new/deep.jpg",
        "cv-x/top.jpg",
        "rootfile.jpg",
    ]


def test_depth_one_still_covers_whole_tree(tmp_path: Path):
    root = tmp_path / "snap"
    (root / "a" / "b").mkdir(parents=True)
    (root / "top.jpg").write_bytes(b"a")
    (root / "a" / "one.jpg").write_bytes(b"b")
    (root / "a" / "b" / "two.jpg").write_bytes(b"c")

    mirror = tmp_path / "mirror"
    conn = init_db(mirror / ".state" / "vision.db")
    try:
        stable_and_copy(_sync_cfg(mirror, tmp_path, depth=1), root, conn)
        count = len(_synced_paths(conn))
    finally:
        conn.close()

    assert count == 3


def test_offline_force_stable_copies_on_first_pass(tmp_path: Path):
    """offline-maint runs force_stable=True so files written just before a
    rotation are captured in the single offline pass instead of being wiped."""
    root = tmp_path / "snap"
    root.mkdir()
    (root / "fresh.jpg").write_bytes(b"x")

    mirror = tmp_path / "mirror"
    conn = init_db(mirror / ".state" / "vision.db")
    cfg = _sync_cfg(mirror, tmp_path, depth=1)
    cfg.stable_scans = 2  # normal path needs two stable scans
    try:
        stable_and_copy(cfg, root, conn)  # one normal pass: not yet stable
        assert conn.execute("SELECT COUNT(*) FROM synced_files").fetchone()[0] == 0
        stable_and_copy(cfg, root, conn, force_stable=True)  # offline: copy now
        assert conn.execute("SELECT COUNT(*) FROM synced_files").fetchone()[0] == 1
    finally:
        conn.close()


def test_sync_is_idempotent_across_runs(tmp_path: Path):
    root = tmp_path / "snap"
    root.mkdir()
    (root / "top.jpg").write_bytes(b"a")

    mirror = tmp_path / "mirror"
    conn = init_db(mirror / ".state" / "vision.db")
    cfg = _sync_cfg(mirror, tmp_path, depth=1)
    try:
        stable_and_copy(cfg, root, conn)
        stable_and_copy(cfg, root, conn)
        count = conn.execute("SELECT COUNT(*) FROM synced_files").fetchone()[0]
    finally:
        conn.close()

    assert count == 1

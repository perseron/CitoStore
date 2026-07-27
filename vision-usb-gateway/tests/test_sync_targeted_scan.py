import os
import time
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
        sync_hot_window_sec=0,
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

    # Spread far wider than the hot window so only "new" is recent relative
    # to the newest observed mtime.
    _touch_dir(root / "old", 100)
    _touch_dir(root / "mid", 100_000)
    _touch_dir(root / "new", 200_000)

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
    # The single-child, file-free cv-x/image/SD1_000 chain is treated as a
    # constant prefix (System Volume Information is ignored for that
    # decision); the sessions become depth-1 units below it — same scan
    # units as the old explicit-depth behaviour reached.
    assert plan["prefix"] == "cv-x/image/SD1_000"
    assert [p.as_posix() for p in roots] == [
        (root / "cv-x/image/SD1_000/session_new").as_posix(),
        (root / "cv-x/image/SD1_000/session_old").as_posix(),
    ]
    # Every level above the units must still be scanned non-recursively.
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


def test_full_scan_selects_every_dir_and_leaves_cursor_alone(tmp_path: Path):
    root = tmp_path / "snap"
    root.mkdir()
    for i in range(6):
        _touch_dir(root / f"d{i}", 100 + i)

    idx = tmp_path / "sync-dir-index-full.json"
    cfg = SimpleNamespace(
        sync_scan_depth=1,
        sync_hot_dirs=1,
        sync_hot_window_sec=0,
        sync_cold_audit_dirs_per_run=1,
        sync_dir_index_file=idx,
    )

    roots, plan = select_scan_roots(cfg, root, full_scan=True)
    assert sorted(p.name for p in roots) == [f"d{i}" for i in range(6)]
    assert sorted(plan["selected"]) == [f"d{i}" for i in range(6)]
    # The offline pass must not advance the live round-robin state.
    assert not idx.exists()


def test_offline_full_scan_captures_dirs_the_live_selection_missed(tmp_path: Path):
    """Regression for the rotation data-destruction bug: the offline export
    inherited the live hot/cold 2-dir selection, so the reformat that follows
    destroyed every file in the unselected directories (measured 46% total
    loss under the real nested date/SceneGroup/Scene/OK-NG layout). Two date
    folders so the top level is not a skippable single-dir prefix."""
    root = tmp_path / "snap"
    leaves = ["day1/SG1/S1/OK", "day1/SG1/S1/NG", "day2/SG2/S1/OK", "day2/SG2/S2/NG"]
    for leaf in leaves:
        d = root / leaf
        d.mkdir(parents=True)
        (d / f"{leaf.replace('/', '_')}.jpg").write_bytes(leaf.encode())

    mirror = tmp_path / "mirror"
    conn = init_db(mirror / ".state" / "vision.db")
    cfg = _sync_cfg(mirror, tmp_path, depth=4)
    cfg.sync_hot_dirs = 1
    cfg.sync_cold_audit_dirs_per_run = 0  # live selection sees ONE leaf only
    try:
        stable_and_copy(cfg, root, conn)  # live pass: 1 of 4 leaves
        live_count = conn.execute("SELECT COUNT(*) FROM synced_files").fetchone()[0]
        assert live_count == 1
        # offline-maint's pre-wipe export: must capture the other 3 leaves.
        stable_and_copy(cfg, root, conn, force_stable=True, full_scan=True)
        total = conn.execute("SELECT COUNT(*) FROM synced_files").fetchone()[0]
    finally:
        conn.close()

    assert total == 4


def test_hot_window_promotes_every_recently_written_dir(tmp_path: Path):
    """A single AOI burst touches ~8 leaves; every dir written inside the hot
    window must be hot, not just the single newest one."""
    root = tmp_path / "snap"
    root.mkdir()
    now = int(time.time())
    for i in range(5):
        _touch_dir(root / f"active{i}", now - 10 - i)
    _touch_dir(root / "closed", now - 7200)

    cfg = SimpleNamespace(
        sync_scan_depth=1,
        sync_hot_dirs=1,
        sync_hot_window_sec=300,
        sync_cold_audit_dirs_per_run=1,
        sync_dir_index_file=tmp_path / "sync-dir-index-hot.json",
    )

    roots, plan = select_scan_roots(cfg, root)
    assert sorted(plan["hot"]) == [f"active{i}" for i in range(5)]
    assert plan["audit"] == ["closed"]
    assert len(roots) == 6


def test_prefix_dirs_are_skipped_and_granularity_preserved(tmp_path: Path):
    """A customer repointing the AOI save path prepends constant folders
    (VisionData/Line1/...). The scan must rebase below them so the depth-4
    units stay date/SG/Scene/OK-NG — with no config change. Two date folders,
    as in any real run: the skip must stop at the constant prefix and not
    consume the date level."""
    root = tmp_path / "snap"
    base = 883_612_800
    leaves = ["d1/SG1/S1/OK", "d1/SG1/S1/NG", "d2/SG2/S1/OK"]
    for leaf in leaves:
        d = root / "VisionData" / "Line1" / leaf
        d.mkdir(parents=True)
        (d / f"{leaf.replace('/', '_')}.jpg").write_bytes(leaf.encode())
        os.utime(d, (base, base))

    cfg = SimpleNamespace(
        sync_scan_depth=4,
        sync_hot_dirs=1,
        sync_hot_window_sec=300,
        sync_cold_audit_dirs_per_run=1,
        sync_dir_index_file=tmp_path / "sync-dir-index-prefix.json",
    )

    roots, plan = select_scan_roots(cfg, root)
    assert plan["prefix"] == "VisionData/Line1"
    # Units are the OK/NG leaves below the prefix, not intermediate dirs.
    assert sorted(plan["hot"]) == ["d1/SG1/S1/NG", "d1/SG1/S1/OK", "d2/SG2/S1/OK"]
    # The prefix levels themselves stay on the shallow (non-recursive) list
    # so a stray file dropped next to them is still captured.
    assert "VisionData" in plan["shallow"]
    assert "VisionData/Line1" in plan["shallow"]


def test_single_date_folder_edge_stays_fully_covered(tmp_path: Path):
    """Early in an LV's life only ONE date folder exists, so the prefix skip
    descends into it too — the granularity shifts but every file must still
    be captured by the recursive unit scans."""
    root = tmp_path / "snap"
    leaves = ["only-day/SG1/S1/OK", "only-day/SG2/S1/NG"]
    for leaf in leaves:
        d = root / "Vision" / leaf
        d.mkdir(parents=True)
        (d / f"{leaf.replace('/', '_')}.jpg").write_bytes(leaf.encode())

    mirror = tmp_path / "mirror"
    conn = init_db(mirror / ".state" / "vision.db")
    cfg = _sync_cfg(mirror, tmp_path, depth=4)
    try:
        stable_and_copy(cfg, root, conn)
        got = _synced_paths(conn)
    finally:
        conn.close()

    assert got == sorted(
        f"Vision/{leaf}/{leaf.replace('/', '_')}.jpg" for leaf in leaves
    )


def test_deep_prefixed_layout_full_copy_and_offline_export(tmp_path: Path):
    """End-to-end with 2 extra leading levels: the live pass and the offline
    full export must both capture every file, mirrored under the FULL
    original path (prefix included)."""
    root = tmp_path / "snap"
    leaves = ["d1/SG1/S1/OK", "d1/SG1/S1/NG", "d1/SG2/S1/OK", "d1/SG2/S2/NG"]
    for leaf in leaves:
        d = root / "Vision" / "L1" / leaf
        d.mkdir(parents=True)
        (d / f"{leaf.replace('/', '_')}.jpg").write_bytes(leaf.encode())

    mirror = tmp_path / "mirror"
    conn = init_db(mirror / ".state" / "vision.db")
    cfg = _sync_cfg(mirror, tmp_path, depth=4)
    try:
        stable_and_copy(cfg, root, conn, force_stable=True, full_scan=True)
        got = _synced_paths(conn)
    finally:
        conn.close()

    assert got == sorted(
        f"Vision/L1/{leaf}/{leaf.replace('/', '_')}.jpg" for leaf in leaves
    )


def test_observed_file_mtime_keeps_deep_subtree_hot(tmp_path: Path):
    """Directory mtimes only move when a DIRECT child appears; on a layout
    deeper than SYNC_SCAN_DEPTH the scan unit is an intermediate dir whose
    mtime goes stale while files pour in below it. The newest file mtime a
    scan observed must keep that unit hot on the next selection."""
    root = tmp_path / "snap"
    base = 883_612_800
    # Two units at depth 1; "active" has a subdir with a FRESH file but a
    # STALE dir mtime, "idle" has newer dir mtime than active's dir.
    active_leaf = root / "active" / "deep"
    active_leaf.mkdir(parents=True)
    f = active_leaf / "fresh.jpg"
    f.write_bytes(b"x")
    os.utime(f, (base + 10_000, base + 10_000))
    os.utime(active_leaf, (base, base))
    os.utime(root / "active", (base, base))
    idle = root / "idle"
    idle.mkdir()
    os.utime(idle, (base + 500, base + 500))

    mirror = tmp_path / "mirror"
    conn = init_db(mirror / ".state" / "vision.db")
    cfg = _sync_cfg(mirror, tmp_path, depth=1)
    cfg.sync_hot_dirs = 1
    cfg.sync_hot_window_sec = 300
    cfg.sync_cold_audit_dirs_per_run = 1
    try:
        # Without the observed-mtime signal, "idle" (newer dir mtime) wins
        # the hot slot...
        _, plan_before = select_scan_roots(cfg, root)
        assert plan_before["hot"] == ["idle"]
        # ...but a scan pass records active's fresh FILE mtime...
        stable_and_copy(cfg, root, conn)
        # ...so the next selection puts "active" on top.
        _, plan_after = select_scan_roots(cfg, root)
        assert plan_after["hot"][0] == "active"
    finally:
        conn.close()


def test_hot_window_is_clock_independent(tmp_path: Path):
    """The window is measured against the newest OBSERVED mtime, never this
    machine's clock — an AOI host's clock can be decades wrong (dead CMOS on
    a Win98-era PC) and recent-relative-to-itself must still mean hot."""
    root = tmp_path / "snap"
    root.mkdir()
    base = 883_612_800  # 1998-01-01, decades behind any board clock
    for i in range(4):
        _touch_dir(root / f"active{i}", base - 10 - i)
    _touch_dir(root / "closed", base - 7200)

    cfg = SimpleNamespace(
        sync_scan_depth=1,
        sync_hot_dirs=1,
        sync_hot_window_sec=300,
        sync_cold_audit_dirs_per_run=1,
        sync_dir_index_file=tmp_path / "sync-dir-index-1998.json",
    )

    roots, plan = select_scan_roots(cfg, root)
    assert sorted(plan["hot"]) == [f"active{i}" for i in range(4)]
    assert plan["audit"] == ["closed"]

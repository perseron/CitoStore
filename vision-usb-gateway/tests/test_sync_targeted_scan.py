import os
from pathlib import Path
from types import SimpleNamespace

from vision_sync.sync import select_scan_roots


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

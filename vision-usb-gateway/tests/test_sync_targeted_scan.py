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

"""aoi_settings change check: a slow (large) folder is not re-walked every cycle."""
import sys
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

import vision_sync.sync as s


@pytest.fixture
def unit(tmp_path, monkeypatch):
    root = tmp_path / "snap"
    (root / "aoi_settings").mkdir(parents=True)
    (root / "aoi_settings" / "a.cfg").write_text("x")
    backing = tmp_path / "backing"
    backing.mkdir()
    state = tmp_path / "state"
    state.mkdir()
    cfg = types.SimpleNamespace(usb_persist_dir="aoi_settings", usb_persist_backing=backing,
                                state_dir=state, lvm_vg="vg0", usb_lvs=["usb_0", "usb_1"],
                                usb_persist_recheck_sec=120)
    walks = []
    monkeypatch.setattr(s, "persist_enabled", lambda c: True)
    monkeypatch.setattr(s, "mount_rw", lambda *a, **k: None)
    monkeypatch.setattr(s, "umount", lambda *a, **k: None)
    monkeypatch.setattr(s, "sync_dir", lambda *a, **k: None)
    monkeypatch.setattr(s, "log", lambda *a, **k: None)
    return cfg, root, walks, monkeypatch


def _walk_taking(walks, monkeypatch, seconds):
    clock = {"t": 1000.0}

    def fake_monotonic():
        return clock["t"]

    def fake_manifest(path):
        walks.append(path)
        clock["t"] += seconds
        return f"digest-{len(walks)}"

    monkeypatch.setattr(s.time, "monotonic", fake_monotonic)
    monkeypatch.setattr(s, "compute_manifest", fake_manifest)


def _run_at(cfg, root, monkeypatch, now):
    monkeypatch.setattr(s.time, "time", lambda: now)
    s.maybe_sync_persist(cfg, root, "/dev/vg0/usb_0")


def test_a_small_folder_is_still_checked_every_cycle(unit):
    cfg, root, walks, mp = unit
    _walk_taking(walks, mp, 0.05)
    for t in (0, 10, 20, 30):
        _run_at(cfg, root, mp, 1_000_000 + t)
    assert len(walks) == 4


def test_a_slow_folder_is_rewalked_only_every_recheck_interval(unit):
    cfg, root, walks, mp = unit
    _walk_taking(walks, mp, 1.8)            # 5000 files on a cold snapshot, measured
    for t in range(0, 120, 10):             # twelve cycles inside two minutes
        _run_at(cfg, root, mp, 1_000_000 + t)
    assert len(walks) == 1
    _run_at(cfg, root, mp, 1_000_000 + 120)
    assert len(walks) == 2


def test_clock_set_back_does_not_freeze_the_check(unit):
    cfg, root, walks, mp = unit
    _walk_taking(walks, mp, 1.8)
    _run_at(cfg, root, mp, 2_000_000)
    _run_at(cfg, root, mp, 1_000_000)       # "Set Time" moved the clock back
    assert len(walks) == 2


def test_unreadable_check_state_means_check(unit):
    cfg, root, walks, mp = unit
    _walk_taking(walks, mp, 1.8)
    (cfg.state_dir / "usb_persist.check").write_text("garbage")
    _run_at(cfg, root, mp, 1_000_000)
    assert len(walks) == 1


def test_throttled_cycle_tells_the_scan_to_leave_the_folder_out(unit):
    cfg, root, walks, mp = unit
    _walk_taking(walks, mp, 1.8)
    mp.setattr(s.time, "time", lambda: 1_000_000)
    assert s.maybe_sync_persist(cfg, root, "/dev/vg0/usb_0") is True    # walked
    mp.setattr(s.time, "time", lambda: 1_000_030)
    assert s.maybe_sync_persist(cfg, root, "/dev/vg0/usb_0") is False   # throttled


def test_small_folder_is_always_scanned(unit):
    cfg, root, walks, mp = unit
    _walk_taking(walks, mp, 0.05)
    for t in (0, 30, 60):
        mp.setattr(s.time, "time", lambda t=t: 1_000_000 + t)
        assert s.maybe_sync_persist(cfg, root, "/dev/vg0/usb_0") is True


def test_image_scan_skips_the_settings_folder_only_when_told(tmp_path):
    from vision_sync.db import init_db
    root = tmp_path / "snap"
    img_dir = root / "AOI_Images" / "2026" / "10" / "02"
    img_dir.mkdir(parents=True)
    (img_dir / "img_1.bmp").write_bytes(b"image")
    (root / "aoi_settings").mkdir()
    (root / "aoi_settings" / "machine.cfg").write_bytes(b"settings")
    mirror = tmp_path / "mirror"
    cfg = types.SimpleNamespace(
        mirror_mount=mirror, state_dir=mirror / ".state", mirror_free_min_mb=0,
        mirror_retention_trigger_pct=101, max_file_size=4 * 1024**3, stable_scans=1,
        copy_chunk=1 << 20, append_always=False, bydate_use_file_time=False,
        sync_log_every=0, sync_scan_depth=1, sync_hot_dirs=8, sync_hot_window_sec=0,
        sync_cold_audit_dirs_per_run=8, sync_dir_index_file=tmp_path / "idx.json",
        usb_persist_dir="aoi_settings",
    )

    def synced(conn):
        return sorted(Path(r[0]).name for r in conn.execute("SELECT source_path FROM synced_files"))

    conn = init_db(mirror / ".state" / "vision.db")
    try:
        s.stable_and_copy(cfg, root, conn, skip_top=frozenset({"aoi_settings"}))
        assert synced(conn) == ["img_1.bmp"]           # images still captured
        s.stable_and_copy(cfg, root, conn)
        assert synced(conn) == ["img_1.bmp", "machine.cfg"]   # next full cycle
    finally:
        conn.close()

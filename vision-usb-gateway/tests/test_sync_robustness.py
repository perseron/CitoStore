"""2026-10-05 review: one bad file must not stop capture, long names fit ext4,
same-name images get their own bydate entry, an export that copied nothing
says so, and nothing is copied into an unmounted mirror."""
import errno
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest

from vision_sync import sync as s
from vision_sync.db import init_db


def cfg_for(mirror: Path, tmp_path: Path, free_min_mb: int = 0) -> SimpleNamespace:
    return SimpleNamespace(
        mirror_mount=mirror,
        state_dir=mirror / ".state",
        mirror_free_min_mb=free_min_mb,
        mirror_retention_trigger_pct=101,
        max_file_size=4 * 1024**3,
        stable_scans=1,
        copy_chunk=1 << 20,
        append_always=False,
        bydate_use_file_time=False,
        sync_log_every=0,
        sync_scan_depth=4,
        sync_hot_dirs=8,
        sync_hot_window_sec=0,
        sync_cold_audit_dirs_per_run=8,
        sync_dir_index_file=tmp_path / "idx.json",
    )


@pytest.fixture
def unit(tmp_path, monkeypatch):
    mirror = tmp_path / "mirror"
    (mirror / ".state").mkdir(parents=True)
    drive = tmp_path / "drive"
    drive.mkdir()
    conn = init_db(mirror / ".state" / "vision.db")
    monkeypatch.setattr(s.subprocess, "run", lambda *a, **k: None)  # no systemctl
    return mirror, drive, conn, cfg_for(mirror, tmp_path)


def put(drive: Path, rel: str, data: bytes = b"x") -> None:
    p = drive / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


def synced(conn) -> list:
    return sorted(r[0] for r in conn.execute("SELECT source_path FROM synced_files"))


def test_one_unreadable_file_does_not_stop_the_others(unit, monkeypatch):
    mirror, drive, conn, cfg = unit
    for name in ("A/a1.jpg", "A/bad.jpg", "A/a2.jpg", "B/b1.jpg"):
        put(drive, name)
    real = s.atomic_copy

    def flaky(src, *a, **k):
        if src.name == "bad.jpg":
            raise OSError(errno.EIO, "Input/output error")
        return real(src, *a, **k)

    monkeypatch.setattr(s, "atomic_copy", flaky)
    result = s.stable_and_copy(cfg, drive, conn, force_stable=True, full_scan=True)
    assert result["failed"] == 1
    assert synced(conn) == ["A/a1.jpg", "A/a2.jpg", "B/b1.jpg"]
    # ...and the next cycle copies nothing twice (it used to roll back and
    # re-copy every file before the bad one as a hashed duplicate).
    s.stable_and_copy(cfg, drive, conn, force_stable=True, full_scan=True)
    assert sorted(p.name for p in (mirror / "raw" / "A").iterdir()) == ["a1.jpg", "a2.jpg"]


def test_a_full_mirror_mid_cycle_keeps_what_was_copied(unit, monkeypatch):
    mirror, drive, conn, cfg = unit
    for name in ("a.jpg", "b.jpg", "c.jpg"):
        put(drive, name)
    real = s.atomic_copy
    calls = []

    def filling(src, *a, **k):
        calls.append(src.name)
        if len(calls) == 2:
            raise OSError(errno.ENOSPC, "No space left on device")
        return real(src, *a, **k)

    monkeypatch.setattr(s, "atomic_copy", filling)
    result = s.stable_and_copy(cfg, drive, conn, force_stable=True, full_scan=True)
    assert result["mirror_full"] and result["synced"] == 1
    assert len(synced(conn)) == 1          # committed, not rolled back


def test_a_name_too_long_for_ext4_is_shortened_uniquely():
    long = "漢" * 120 + ".jpg"             # 360 bytes of UTF-8
    other = "漢" * 119 + "x.jpg"
    a, b = s.fit_name(long), s.fit_name(other)
    assert len(a.encode()) <= s.NAME_BYTES_MAX and a.endswith(".jpg")
    assert a != b
    assert s.fit_name("short.jpg") == "short.jpg"


def test_same_name_same_day_gets_its_own_bydate_entry(unit):
    mirror, drive, conn, cfg = unit
    put(drive, "S1/BOARD001.jpg", b"one")
    put(drive, "S2/BOARD001.jpg", b"two")
    s.stable_and_copy(cfg, drive, conn, force_stable=True, full_scan=True)
    links = sorted(p.read_bytes() for p in (mirror / "bydate").rglob("*.jpg"))
    assert links == [b"one", b"two"]
    rows = conn.execute("SELECT bydate_path FROM synced_files").fetchall()
    assert len({r[0] for r in rows}) == 2


def test_an_export_that_copied_nothing_is_recorded(unit, tmp_path, monkeypatch):
    mirror, drive, conn, cfg = unit
    put(drive, "a.jpg")
    cfg.mirror_free_min_mb = 10**9                      # "full"
    monkeypatch.setattr(s.os.path, "ismount", lambda p: True)
    monkeypatch.setattr(s, "init_db", lambda p: conn)
    monkeypatch.setattr(s, "read_active", lambda: "/dev/vg0/usb_1")
    monkeypatch.setattr(s, "get_partition_offset", lambda d: None)
    monkeypatch.setattr(s, "mount_ro", lambda *a, **k: None)
    monkeypatch.setattr(s, "umount", lambda *a, **k: None)
    monkeypatch.setattr(s, "record_snapshot_usage", lambda *a, **k: None)
    cfg.snapshot_mount = drive
    s.run(cfg, "/dev/vg0/usb_0", offline=True)
    rec = json.loads((mirror / ".state" / "export-not-saved.json").read_text())
    assert rec["dev"] == "/dev/vg0/usb_0" and "full" in rec["reason"]


def test_nothing_is_copied_into_an_unmounted_mirror(unit, monkeypatch):
    mirror, drive, conn, cfg = unit
    monkeypatch.setattr(s.os.path, "ismount", lambda p: False)
    with pytest.raises(SystemExit):
        s.run(cfg, None, offline=False)


def test_the_preseed_waits_its_turn_for_usb_maintenance(tmp_path, monkeypatch):
    import fcntl
    lockfile = tmp_path / "usb.lock"
    monkeypatch.setattr(s, "USB_LOCK_FILE", str(lockfile))
    held = open(lockfile, "a")
    fcntl.flock(held, fcntl.LOCK_EX)
    assert s.usb_lock_nowait() is None
    held.close()
    got = s.usb_lock_nowait()
    assert got is not None
    got.close()

import argparse
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

from .config import get_config
from .db import init_db, update_state, is_already_synced, mark_synced
from .fsops import iter_files, atomic_copy


ACTIVE_FILE = "/run/vision-usb-active"


def log(msg: str) -> None:
    print(msg, flush=True)


def read_active() -> str:
    if not os.path.exists(ACTIVE_FILE):
        raise RuntimeError("active device file missing")
    return Path(ACTIVE_FILE).read_text().strip()


def lv_snapshot(active_dev: str, vg: str, snap_name: str) -> str:
    snap_path = f"/dev/{vg}/{snap_name}"
    subprocess.run(["lvremove", "-y", snap_path], check=False)
    subprocess.run(["lvcreate", "-s", "-n", snap_name, active_dev], check=True)
    # Ensure the snapshot is activatable and active so a device node appears.
    subprocess.run(["lvchange", "-K", "n", snap_path], check=False)
    subprocess.run(["lvchange", "-ay", snap_path], check=False)
    return wait_for_dev(snap_path, vg, snap_name)


def lv_remove(snap_name: str, vg: str) -> None:
    subprocess.run(["lvremove", "-y", f"/dev/{vg}/{snap_name}"], check=False)


def mount_ro(dev: str, mount_point: Path) -> None:
    mount_point.mkdir(parents=True, exist_ok=True)
    opts = "ro,utf8,shortname=mixed,nodev,nosuid,noexec"
    subprocess.run(["mount", "-t", "vfat", "-o", opts, dev, str(mount_point)], check=True)


def wait_for_dev(snap_path: str, vg: str, snap_name: str) -> str:
    mapper_path = f"/dev/mapper/{vg}-{snap_name}"

    # Give udev a moment to create nodes after lvcreate.
    udevadm = "/sbin/udevadm"
    if os.path.exists(udevadm):
        subprocess.run([udevadm, "settle"], check=False)

    for _ in range(50):  # ~5s total
        if os.path.exists(snap_path):
            return snap_path
        if os.path.exists(mapper_path):
            return mapper_path
        time.sleep(0.1)

    # Last attempt to create nodes directly.
    dmsetup = "/sbin/dmsetup"
    if os.path.exists(dmsetup):
        subprocess.run([dmsetup, "mknodes"], check=False)
        if os.path.exists(snap_path):
            return snap_path
        if os.path.exists(mapper_path):
            return mapper_path

    raise RuntimeError(f"snapshot device node missing: {snap_path}")


def umount(mount_point: Path) -> None:
    subprocess.run(["umount", str(mount_point)], check=False)


def stable_and_copy(cfg, mount_root: Path, conn) -> None:
    raw_dir = cfg.mirror_mount / "raw"
    bydate_dir = cfg.mirror_mount / "bydate"
    now = int(time.time())

    for path, st in iter_files(mount_root):
        rel = path.relative_to(mount_root)
        size = int(st.st_size)
        mtime = int(st.st_mtime)
        if size >= cfg.max_file_size:
            log(f"skip too large: {rel}")
            continue

        stable = update_state(conn, str(rel), size, mtime, now)
        if stable < cfg.stable_scans:
            continue

        if is_already_synced(conn, str(rel), size, mtime):
            continue

        dt = datetime.fromtimestamp(mtime)
        date_path = bydate_dir / dt.strftime("%Y/%m/%d")

        name = rel.name
        stem = Path(name).stem
        suffix = Path(name).suffix
        final_name = f"{stem}_{mtime}{suffix}"

        dest_path, digest = atomic_copy(path, raw_dir, final_name, cfg.copy_chunk)

        hash_name = f"{Path(final_name).stem}_{digest[:8]}{suffix}"
        hash_path = raw_dir / hash_name
        if hash_path.exists():
            dest_path.unlink(missing_ok=True)
            final_path = hash_path
        else:
            dest_path.rename(hash_path)
            final_path = hash_path

        date_path.mkdir(parents=True, exist_ok=True)
        link_path = date_path / hash_name
        if not link_path.exists():
            os.link(final_path, link_path)

        mark_synced(conn, str(rel), size, mtime, str(final_path), str(link_path), now)
        log(f"synced: {rel}")


def run(cfg, dev_override: str | None, offline: bool) -> None:
    conn = init_db(cfg.state_dir / "vision.db")

    if dev_override:
        dev = dev_override
        active = read_active()
        if dev == active:
            raise RuntimeError("refusing to mount active device")
        mount_ro(dev, cfg.snapshot_mount)
        try:
            stable_and_copy(cfg, cfg.snapshot_mount, conn)
        finally:
            umount(cfg.snapshot_mount)
        return

    active = read_active()
    snap = lv_snapshot(active, cfg.lvm_vg, cfg.snapshot_name)
    try:
        mount_ro(snap, cfg.snapshot_mount)
        stable_and_copy(cfg, cfg.snapshot_mount, conn)
    finally:
        umount(cfg.snapshot_mount)
        lv_remove(cfg.snapshot_name, cfg.lvm_vg)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="/etc/vision-gw.conf")
    parser.add_argument("--dev", default=None)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()

    cfg = get_config(args.config)
    run(cfg, args.dev, args.offline)


if __name__ == "__main__":
    main()

import argparse
import os
import subprocess
import time
import shutil
from datetime import datetime
from pathlib import Path

from .config import get_config
from .db import init_db, update_state, is_already_synced, mark_synced
from .fsops import iter_files, atomic_copy, safe_join, compute_manifest


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
    # Different LVM versions expose different flags, so try both.
    subprocess.run(["lvchange", "--setactivationskip", "n", snap_path], check=False)
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

def persist_enabled(cfg) -> bool:
    return bool(cfg.usb_persist_dir) and cfg.usb_persist_dir != "none"


def next_lv(active_dev: str, lvm_vg: str, usb_lvs: list[str]) -> str | None:
    if not usb_lvs:
        return None
    name = Path(active_dev).name
    idx = -1
    for i, lv in enumerate(usb_lvs):
        if lv == name:
            idx = i
            break
    if idx < 0:
        return f"/dev/{lvm_vg}/{usb_lvs[0]}"
    if len(usb_lvs) == 1:
        return None
    nxt = (idx + 1) % len(usb_lvs)
    return f"/dev/{lvm_vg}/{usb_lvs[nxt]}"


def read_manifest_state(path: Path) -> tuple[str, int]:
    if not path.exists():
        return "", 0
    content = path.read_text().strip().splitlines()
    if not content:
        return "", 0
    if len(content) == 1 and "=" not in content[0]:
        return content[0].strip(), 0
    digest = ""
    count = 0
    for line in content:
        if line.startswith("digest="):
            digest = line.split("=", 1)[1].strip()
        elif line.startswith("count="):
            try:
                count = int(line.split("=", 1)[1].strip())
            except ValueError:
                count = 0
    return digest, count


def write_manifest_state(path: Path, digest: str, count: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"digest={digest}\ncount={count}\n")


def sync_dir(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    rsync = shutil.which("rsync")
    if rsync:
        subprocess.run(
            [rsync, "-rlt", "--delete", "--no-owner", "--no-group", "--no-perms", f"{src}/", f"{dst}/"],
            check=True,
        )
        return
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def mount_rw(dev: str, mount_point: Path) -> None:
    mount_point.mkdir(parents=True, exist_ok=True)
    opts = "utf8,shortname=mixed,nodev,nosuid,noexec"
    subprocess.run(["mount", "-t", "vfat", "-o", opts, dev, str(mount_point)], check=True)


def maybe_sync_persist(cfg, mount_root: Path, active_dev: str) -> None:
    if not persist_enabled(cfg):
        return
    persist_src = mount_root / cfg.usb_persist_dir
    if not persist_src.exists():
        return

    manifest_path = cfg.state_dir / "usb_persist.manifest"
    new_digest = compute_manifest(persist_src)
    old_digest = read_manifest(manifest_path)
    if new_digest == old_digest:
        return

    log(f"persist changed: syncing {cfg.usb_persist_dir}")
    cfg.usb_persist_backing.mkdir(parents=True, exist_ok=True)
    sync_dir(persist_src, cfg.usb_persist_backing)

    next_dev = next_lv(active_dev, cfg.lvm_vg, cfg.usb_lvs)
    if next_dev:
        persist_mnt = Path("/mnt/vision_persist_next")
        try:
            mount_rw(next_dev, persist_mnt)
            dest = persist_mnt / cfg.usb_persist_dir
            sync_dir(cfg.usb_persist_backing, dest)
        except Exception as exc:
            log(f"persist preseed failed for {next_dev}: {exc}")
        finally:
            umount(persist_mnt)

    write_manifest(manifest_path, new_digest)


def maybe_compute_sync_manifest(cfg, mount_root: Path) -> tuple[str, int, bool] | None:
    if not getattr(cfg, "sync_change_detect", False):
        return None
    manifest_path = cfg.sync_manifest_path
    new_digest = compute_manifest(mount_root)
    old_digest, old_count = read_manifest_state(manifest_path)
    if new_digest == old_digest:
        return new_digest, old_count + 1, True
    return new_digest, 1, False

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

        raw_subdir = safe_join(raw_dir, rel.parent)
        dest_path, digest = atomic_copy(path, raw_subdir, final_name, cfg.copy_chunk)

        hash_name = f"{Path(final_name).stem}_{digest[:8]}{suffix}"
        hash_path = raw_subdir / hash_name
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
        sync_manifest = None
        if not offline:
            maybe_sync_persist(cfg, cfg.snapshot_mount, active)
            sync_manifest = maybe_compute_sync_manifest(cfg, cfg.snapshot_mount)
            if sync_manifest:
                digest, count, unchanged = sync_manifest
                if digest and unchanged and count >= cfg.stable_scans:
                    log("sync: no changes since last run; skipping copy")
                    if count > cfg.stable_scans:
                        count = cfg.stable_scans
                    prev_digest, prev_count = read_manifest_state(cfg.sync_manifest_path)
                    if prev_digest != digest or prev_count != count:
                        write_manifest_state(cfg.sync_manifest_path, digest, count)
                    return
        stable_and_copy(cfg, cfg.snapshot_mount, conn)
        if not offline and sync_manifest:
            digest, count, _ = sync_manifest
            if count > cfg.stable_scans:
                count = cfg.stable_scans
            prev_digest, prev_count = read_manifest_state(cfg.sync_manifest_path)
            if prev_digest != digest or prev_count != count:
                write_manifest_state(cfg.sync_manifest_path, digest, count)
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

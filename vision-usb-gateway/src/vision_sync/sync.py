import argparse
import os
import subprocess
import time
import shutil
from datetime import datetime
from pathlib import Path
import json

from .config import get_config
from .db import init_db, update_state, is_already_synced, mark_synced
from .fsops import iter_files, atomic_copy, safe_join, compute_manifest


ACTIVE_FILE = "/run/vision-usb-active"
USB_USAGE_FILE = "/run/vision-usb-usage.json"


def log(msg: str) -> None:
    print(msg, flush=True)


def run_best_effort(args: list[str]) -> None:
    subprocess.run(args, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def read_active() -> str:
    if not os.path.exists(ACTIVE_FILE):
        raise RuntimeError("active device file missing")
    return Path(ACTIVE_FILE).read_text().strip()


def lv_snapshot(active_dev: str, vg: str, snap_name: str) -> str:
    snap_path = f"/dev/{vg}/{snap_name}"
    kpartx = "/sbin/kpartx"
    if not os.path.exists(kpartx):
        kpartx = "/usr/sbin/kpartx"
    if os.path.exists(kpartx):
        subprocess.run([kpartx, "-d", snap_path], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    partx = "/sbin/partx"
    if not os.path.exists(partx):
        partx = "/usr/sbin/partx"
    if os.path.exists(partx):
        subprocess.run([partx, "-d", snap_path], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dmsetup = "/sbin/dmsetup"
    if not os.path.exists(dmsetup):
        dmsetup = "/usr/sbin/dmsetup"
    if os.path.exists(dmsetup):
        subprocess.run([dmsetup, "remove", "-f", f"{vg}-{snap_name}1"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([dmsetup, "remove", "-f", f"{vg}-{snap_name}"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run_best_effort(["lvremove", "-y", snap_path])
    subprocess.run(["lvcreate", "-s", "-n", snap_name, active_dev], check=True)
    # Ensure the snapshot is activatable and active so a device node appears.
    # Different LVM versions expose different flags, so try both.
    run_best_effort(["lvchange", "--setactivationskip", "n", snap_path])
    run_best_effort(["lvchange", "-K", "n", snap_path])
    run_best_effort(["lvchange", "-ay", snap_path])
    return wait_for_dev(snap_path, vg, snap_name)


def lv_remove(snap_name: str, vg: str) -> None:
    snap_path = f"/dev/{vg}/{snap_name}"
    kpartx = "/sbin/kpartx"
    if not os.path.exists(kpartx):
        kpartx = "/usr/sbin/kpartx"
    if os.path.exists(kpartx):
        subprocess.run([kpartx, "-d", snap_path], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    partx = "/sbin/partx"
    if not os.path.exists(partx):
        partx = "/usr/sbin/partx"
    if os.path.exists(partx):
        subprocess.run([partx, "-d", snap_path], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dmsetup = "/sbin/dmsetup"
    if not os.path.exists(dmsetup):
        dmsetup = "/usr/sbin/dmsetup"
    if os.path.exists(dmsetup):
        subprocess.run([dmsetup, "remove", "-f", f"{vg}-{snap_name}1"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([dmsetup, "remove", "-f", f"{vg}-{snap_name}"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run_best_effort(["lvremove", "-y", snap_path])


def mount_ro(dev: str, mount_point: Path, offset_override: int | None = None) -> None:
    mount_point.mkdir(parents=True, exist_ok=True)
    opts = "ro,utf8,shortname=mixed,nodev,nosuid,noexec"
    mount_dev = resolve_mount_device(dev)
    if offset_override is not None:
        offset_opts = f"{opts},loop,offset={offset_override}"
        result = subprocess.run(
            ["mount", "-t", "vfat", "-o", offset_opts, dev, str(mount_point)],
            check=False,
        )
        if result.returncode == 0:
            return
        if os.path.exists(ACTIVE_FILE):
            try:
                alt = get_partition_offset(read_active())
            except Exception:
                alt = None
            if alt and alt != offset_override:
                offset_opts = f"{opts},loop,offset={alt}"
                result = subprocess.run(
                    ["mount", "-t", "vfat", "-o", offset_opts, dev, str(mount_point)],
                    check=False,
                )
                if result.returncode == 0:
                    return
    result = subprocess.run(
        ["mount", "-t", "vfat", "-o", opts, mount_dev, str(mount_point)],
        check=False,
    )
    if result.returncode == 0:
        return
    offset = offset_override or get_partition_offset(dev) or get_partition_offset(mount_dev)
    if offset is None and os.path.exists(ACTIVE_FILE):
        try:
            offset = get_partition_offset(read_active())
        except Exception:
            offset = None
    if offset is None:
        raise subprocess.CalledProcessError(result.returncode, result.args)
    offset_opts = f"{opts},loop,offset={offset}"
    subprocess.run(["mount", "-t", "vfat", "-o", offset_opts, dev, str(mount_point)], check=True)


def record_snapshot_usage(mount_point: Path, active_dev: str) -> None:
    try:
        result = subprocess.run(
            ["df", "-h", "--output=size,used,pcent", str(mount_point)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            return
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if len(lines) < 2:
            return
        parts = lines[1].split()
        if len(parts) < 3:
            return
        payload = {
            "lv": active_dev,
            "size": parts[0],
            "used": parts[1],
            "percent": parts[2],
            "ts": datetime.now().isoformat(timespec="seconds"),
        }
        Path(USB_USAGE_FILE).write_text(json.dumps(payload))
    except Exception:
        return



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


def read_manifest_state(path: Path) -> tuple[str, int, str]:
    if not path.exists():
        return "", 0, "active"
    content = path.read_text().strip().splitlines()
    if not content:
        return "", 0, "active"
    if len(content) == 1 and "=" not in content[0]:
        return content[0].strip(), 0, "active"
    digest = ""
    count = 0
    mode = "active"
    for line in content:
        if line.startswith("digest="):
            digest = line.split("=", 1)[1].strip()
        elif line.startswith("count="):
            try:
                count = int(line.split("=", 1)[1].strip())
            except ValueError:
                count = 0
        elif line.startswith("mode="):
            mode = line.split("=", 1)[1].strip() or "active"
    if mode not in ("active", "suspend"):
        mode = "active"
    return digest, count, mode


def write_manifest_state(path: Path, digest: str, count: int, mode: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if mode not in ("active", "suspend"):
        mode = "active"
    path.write_text(f"digest={digest}\ncount={count}\nmode={mode}\n")


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


def mount_rw(dev: str, mount_point: Path, offset_override: int | None = None) -> None:
    mount_point.mkdir(parents=True, exist_ok=True)
    opts = "utf8,shortname=mixed,nodev,nosuid,noexec"
    mount_dev = resolve_mount_device(dev)
    if offset_override is not None:
        offset_opts = f"{opts},loop,offset={offset_override}"
        result = subprocess.run(
            ["mount", "-t", "vfat", "-o", offset_opts, dev, str(mount_point)],
            check=False,
        )
        if result.returncode == 0:
            return
    result = subprocess.run(
        ["mount", "-t", "vfat", "-o", opts, mount_dev, str(mount_point)],
        check=False,
    )
    if result.returncode == 0:
        return
    offset = offset_override or get_partition_offset(dev) or get_partition_offset(mount_dev)
    if offset is None and os.path.exists(ACTIVE_FILE):
        try:
            offset = get_partition_offset(read_active())
        except Exception:
            offset = None
    if offset is None:
        raise subprocess.CalledProcessError(result.returncode, result.args)
    offset_opts = f"{opts},loop,offset={offset}"
    subprocess.run(["mount", "-t", "vfat", "-o", offset_opts, dev, str(mount_point)], check=True)


def get_partition_offset(dev: str) -> int | None:
    try:
        sfdisk = "/sbin/sfdisk"
        if not os.path.exists(sfdisk):
            sfdisk = "/usr/sbin/sfdisk"
        if not os.path.exists(sfdisk):
            sfdisk = "sfdisk"
        result = subprocess.run(
            [sfdisk, "-d", dev],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if "start=" in line:
                    parts = line.split(",")
                    for part in parts:
                        part = part.strip()
                        if part.startswith("start="):
                            start = int(part.split("=", 1)[1])
                            return start * 512
        # Fall back to lsblk START column (in sectors) if sfdisk output isn't usable.
        lsblk_res = subprocess.run(
            ["lsblk", "-n", "-o", "START", "-r", dev],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if lsblk_res.returncode == 0:
            for line in lsblk_res.stdout.splitlines():
                line = line.strip()
                if line.isdigit():
                    return int(line) * 512
        return None
    except Exception:
        return None


def resolve_mount_device(dev: str) -> str:
    partx = "/sbin/partx"
    if not os.path.exists(partx):
        partx = "/usr/sbin/partx"
    if os.path.exists(partx):
        subprocess.run([partx, "-a", dev], check=False)
    kpartx = "/sbin/kpartx"
    if not os.path.exists(kpartx):
        kpartx = "/usr/sbin/kpartx"
    if os.path.exists(kpartx):
        subprocess.run([kpartx, "-a", dev], check=False)
        # Try to read the mapping name from kpartx output (e.g. vg0-usb_sync_snap1).
        kp = subprocess.run([kpartx, "-l", dev], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        for line in kp.stdout.splitlines():
            name = line.split()[0].strip() if line.split() else ""
            if name:
                mapper = f"/dev/mapper/{name}"
                if os.path.exists(mapper):
                    return mapper
    udevadm = "/sbin/udevadm"
    if os.path.exists(udevadm):
        subprocess.run([udevadm, "settle"], check=False)
    base = os.path.basename(dev)
    mapper_name = base
    if "/dev/" in dev and dev.count("/") >= 2:
        parts = dev.split("/")
        if len(parts) >= 4 and parts[1] == "dev" and parts[2].startswith("vg"):
            vg = parts[2]
            lv = parts[3]
            mapper_name = f"{vg}-{lv}"
    direct_mapper = f"/dev/mapper/{mapper_name}1"
    if os.path.exists(direct_mapper):
        return direct_mapper
    candidates = [
        f"/dev/{base}p1",
        f"/dev/mapper/{mapper_name}p1",
        f"/dev/mapper/{base}p1",
        f"/dev/mapper/{mapper_name}1",
        f"/dev/mapper/{base}1",
    ]
    for cand in candidates:
        if os.path.exists(cand):
            return cand
    result = subprocess.run(
        ["lsblk", "-n", "-o", "NAME,TYPE", "-r", dev],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == "part":
            return f"/dev/{parts[0]}"
    return dev


def maybe_sync_persist(cfg, mount_root: Path, active_dev: str) -> None:
    if not persist_enabled(cfg):
        return
    persist_src = mount_root / cfg.usb_persist_dir
    if not persist_src.exists():
        return

    manifest_path = cfg.state_dir / "usb_persist.manifest"
    new_digest = compute_manifest(persist_src)
    old_digest, _, _ = read_manifest_state(manifest_path)
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

    write_manifest_state(manifest_path, new_digest, 0, "active")


def maybe_compute_sync_manifest(cfg, mount_root: Path) -> tuple[str, int, bool, str] | None:
    if not getattr(cfg, "sync_change_detect", False):
        return None
    manifest_path = cfg.sync_manifest_path
    new_digest = compute_manifest(mount_root)
    old_digest, old_count, old_mode = read_manifest_state(manifest_path)
    if new_digest == old_digest:
        return new_digest, old_count + 1, True, old_mode
    return new_digest, 0, False, "suspend"

def stable_and_copy(cfg, mount_root: Path, conn) -> None:
    raw_dir = cfg.mirror_mount / "raw"
    bydate_dir = cfg.mirror_mount / "bydate"
    now = int(time.time())
    scanned = 0
    synced = 0
    skipped_large = 0
    log_every = max(0, int(getattr(cfg, "sync_log_every", 0)))

    try:
        for path, st in iter_files(mount_root):
            scanned += 1
            rel = path.relative_to(mount_root)
            size = int(st.st_size)
            mtime = int(st.st_mtime)
            if size >= cfg.max_file_size:
                skipped_large += 1
                continue

            stable = update_state(conn, str(rel), size, mtime, now)
            if stable < cfg.stable_scans:
                continue

            if is_already_synced(conn, str(rel), size, mtime):
                continue

            dt = datetime.fromtimestamp(mtime if cfg.bydate_use_file_time else now)
            date_path = bydate_dir / dt.strftime("%Y/%m/%d")

            raw_subdir = safe_join(raw_dir, rel.parent)
            name = rel.name
            stem = Path(name).stem
            suffix = Path(name).suffix
            collision = (raw_subdir / name).exists()
            if cfg.append_always:
                collision = True
            if collision:
                final_name = f"{stem}_{mtime}{suffix}"
            else:
                final_name = name

            dest_path, digest = atomic_copy(path, raw_subdir, final_name, cfg.copy_chunk)

            if collision:
                hash_name = f"{Path(final_name).stem}_{digest[:8]}{suffix}"
                hash_path = raw_subdir / hash_name
                if hash_path.exists():
                    dest_path.unlink(missing_ok=True)
                    final_path = hash_path
                else:
                    dest_path.rename(hash_path)
                    final_path = hash_path
            else:
                final_path = dest_path

            date_path.mkdir(parents=True, exist_ok=True)
            link_path = date_path / final_path.name
            if not link_path.exists():
                os.link(final_path, link_path)

            mark_synced(conn, str(rel), size, mtime, str(final_path), str(link_path), now)
            synced += 1
            if log_every > 0 and synced % log_every == 0:
                log(f"sync progress: synced={synced} scanned={scanned}")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    log(f"sync summary: scanned={scanned} synced={synced} skipped_large={skipped_large}")


def run(cfg, dev_override: str | None, offline: bool) -> None:
    conn = init_db(cfg.state_dir / "vision.db")

    if dev_override:
        dev = dev_override
        active = read_active()
        if dev == active:
            raise RuntimeError("refusing to mount active device")
        active_offset = get_partition_offset(dev)
        mount_ro(dev, cfg.snapshot_mount, active_offset)
        try:
            record_snapshot_usage(cfg.snapshot_mount, dev)
            stable_and_copy(cfg, cfg.snapshot_mount, conn)
        finally:
            umount(cfg.snapshot_mount)
        return

    active = read_active()
    active_offset = get_partition_offset(active)
    snap = lv_snapshot(active, cfg.lvm_vg, cfg.snapshot_name)
    try:
        mount_ro(snap, cfg.snapshot_mount, active_offset)
        record_snapshot_usage(cfg.snapshot_mount, active)
        sync_manifest = None
        if not offline:
            maybe_sync_persist(cfg, cfg.snapshot_mount, active)
            sync_manifest = maybe_compute_sync_manifest(cfg, cfg.snapshot_mount)
            if sync_manifest:
                digest, count, unchanged, mode = sync_manifest
                resume_scans = max(1, int(cfg.sync_change_resume_scans))
                if unchanged:
                    if count > resume_scans:
                        count = resume_scans
                    if mode == "suspend" and count >= resume_scans:
                        mode = "active"
                else:
                    mode = "suspend"
                    count = 0
                if digest and mode == "active" and unchanged and count >= resume_scans:
                    log("sync: no changes since last run; skipping copy")
                    prev_digest, prev_count, prev_mode = read_manifest_state(cfg.sync_manifest_path)
                    if prev_digest != digest or prev_count != count or prev_mode != mode:
                        write_manifest_state(cfg.sync_manifest_path, digest, count, mode)
                    return
        stable_and_copy(cfg, cfg.snapshot_mount, conn)
        if not offline and sync_manifest:
            digest, count, _, mode = sync_manifest
            resume_scans = max(1, int(cfg.sync_change_resume_scans))
            if count > resume_scans:
                count = resume_scans
            prev_digest, prev_count, prev_mode = read_manifest_state(cfg.sync_manifest_path)
            if prev_digest != digest or prev_count != count or prev_mode != mode:
                write_manifest_state(cfg.sync_manifest_path, digest, count, mode)
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

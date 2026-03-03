import argparse
import json
import os
import shutil
import subprocess
import time
from collections.abc import Iterator
from datetime import datetime
from pathlib import Path

from .config import get_config
from .db import init_db, is_already_synced, mark_synced, update_state
from .fsops import SKIP_DIRS, atomic_copy, compute_manifest, iter_files, safe_join

ACTIVE_FILE = "/run/vision-usb-active"
USB_USAGE_FILE = "/run/vision-usb-usage.json"
SYNC_INDEX_VERSION = 1


def log(msg: str) -> None:
    print(msg, flush=True)


def load_dir_index(path: Path) -> dict:
    if not path.exists():
        return {"version": SYNC_INDEX_VERSION, "cursor": 0}
    try:
        raw = json.loads(path.read_text())
        if not isinstance(raw, dict):
            raise ValueError("invalid index")
        return {
            "version": int(raw.get("version", SYNC_INDEX_VERSION)),
            "cursor": int(raw.get("cursor", 0)),
        }
    except Exception:
        return {"version": SYNC_INDEX_VERSION, "cursor": 0}


def save_dir_index(path: Path, state: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {
                    "version": SYNC_INDEX_VERSION,
                    "cursor": int(state.get("cursor", 0)),
                    "ts": datetime.now().isoformat(timespec="seconds"),
                }
            )
        )
    except Exception:
        return


def scan_dirs_at_depth(root: Path, depth: int) -> list[tuple[str, int]]:
    items: list[tuple[str, int]] = []
    if depth <= 0:
        return items
    try:
        for dirpath, dirnames, _ in os.walk(root, topdown=True):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            current = Path(dirpath)
            rel = current.relative_to(root)
            rel_depth = len(rel.parts)
            if rel_depth == depth:
                if rel_depth > 0:
                    try:
                        st = current.stat()
                    except FileNotFoundError:
                        continue
                    items.append((rel.as_posix(), int(st.st_mtime)))
                dirnames[:] = []
                continue
            if rel_depth > depth:
                dirnames[:] = []
                continue
    except FileNotFoundError:
        return []
    items.sort(key=lambda x: (x[1], x[0]), reverse=True)
    return items


def iter_root_files(root: Path) -> Iterator[tuple[Path, os.stat_result]]:
    try:
        for entry in os.scandir(root):
            if not entry.is_file(follow_symlinks=False):
                continue
            p = Path(entry.path)
            try:
                st = p.stat()
            except FileNotFoundError:
                continue
            if not p.is_file():
                continue
            yield p, st
    except FileNotFoundError:
        return


def select_scan_roots(cfg, mount_root: Path) -> tuple[list[Path], dict]:
    scan_depth = max(1, int(getattr(cfg, "sync_scan_depth", 1)))
    dirs = scan_dirs_at_depth(mount_root, scan_depth)
    if not dirs and scan_depth > 1:
        # Safety fallback for shallower layouts.
        dirs = scan_dirs_at_depth(mount_root, 1)
        scan_depth = 1
    dir_names = [name for name, _ in dirs]
    hot_n = max(0, int(getattr(cfg, "sync_hot_dirs", 1)))
    audit_n = max(0, int(getattr(cfg, "sync_cold_audit_dirs_per_run", 1)))

    hot_names = dir_names[:hot_n]
    cold_names = dir_names[hot_n:]

    state = load_dir_index(cfg.sync_dir_index_file)
    cursor = int(state.get("cursor", 0))
    audit_names: list[str] = []
    if cold_names and audit_n > 0:
        start = cursor % len(cold_names)
        take = min(audit_n, len(cold_names))
        for i in range(take):
            idx = (start + i) % len(cold_names)
            audit_names.append(cold_names[idx])
        state["cursor"] = (start + take) % len(cold_names)
    else:
        state["cursor"] = 0
    save_dir_index(cfg.sync_dir_index_file, state)

    selected_names: list[str] = []
    seen = set()
    for name in hot_names + audit_names:
        if name in seen:
            continue
        seen.add(name)
        selected_names.append(name)

    roots = [mount_root / name for name in selected_names]
    plan = {
        "top_dirs": len(dir_names),
        "depth": scan_depth,
        "hot": hot_names,
        "audit": audit_names,
        "selected": selected_names,
    }
    return roots, plan


def _find_tool(name: str, search_paths: tuple[str, ...] = ("/sbin", "/usr/sbin")) -> str | None:
    for prefix in search_paths:
        candidate = f"{prefix}/{name}"
        if os.path.exists(candidate):
            return candidate
    return None


def run_best_effort(args: list[str]) -> None:
    subprocess.run(args, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def read_active() -> str:
    if not os.path.exists(ACTIVE_FILE):
        raise RuntimeError("active device file missing")
    return Path(ACTIVE_FILE).read_text().strip()


def _cleanup_lv_mappings(snap_path: str, vg: str, snap_name: str) -> None:
    kpartx = _find_tool("kpartx")
    if kpartx:
        run_best_effort([kpartx, "-d", snap_path])
    partx = _find_tool("partx")
    if partx:
        run_best_effort([partx, "-d", snap_path])
    dmsetup = _find_tool("dmsetup")
    if dmsetup:
        run_best_effort([dmsetup, "remove", "-f", f"{vg}-{snap_name}1"])
        run_best_effort([dmsetup, "remove", "-f", f"{vg}-{snap_name}"])


def lv_snapshot(active_dev: str, vg: str, snap_name: str) -> str:
    snap_path = f"/dev/{vg}/{snap_name}"
    _cleanup_lv_mappings(snap_path, vg, snap_name)
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
    _cleanup_lv_mappings(snap_path, vg, snap_name)
    run_best_effort(["lvremove", "-y", snap_path])


def _mount_device(
    dev: str, mount_point: Path, *, readonly: bool = True, offset_override: int | None = None
) -> None:
    mount_point.mkdir(parents=True, exist_ok=True)
    common = "utf8,shortname=mixed,nodev,nosuid,noexec"
    base_opts = f"ro,{common}" if readonly else common
    mount_dev = resolve_mount_device(dev)
    if offset_override is not None:
        offset_opts = f"{base_opts},loop,offset={offset_override}"
        result = subprocess.run(
            ["mount", "-t", "vfat", "-o", offset_opts, dev, str(mount_point)],
            check=False,
        )
        if result.returncode == 0:
            return
        if readonly and os.path.exists(ACTIVE_FILE):
            try:
                alt = get_partition_offset(read_active())
            except Exception:
                alt = None
            if alt and alt != offset_override:
                offset_opts = f"{base_opts},loop,offset={alt}"
                result = subprocess.run(
                    ["mount", "-t", "vfat", "-o", offset_opts, dev, str(mount_point)],
                    check=False,
                )
                if result.returncode == 0:
                    return
    result = subprocess.run(
        ["mount", "-t", "vfat", "-o", base_opts, mount_dev, str(mount_point)],
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
    offset_opts = f"{base_opts},loop,offset={offset}"
    subprocess.run(["mount", "-t", "vfat", "-o", offset_opts, dev, str(mount_point)], check=True)


def mount_ro(dev: str, mount_point: Path, offset_override: int | None = None) -> None:
    _mount_device(dev, mount_point, readonly=True, offset_override=offset_override)


def record_snapshot_usage(mount_point: Path, active_dev: str) -> None:
    try:
        result = subprocess.run(
            ["df", "-h", "--output=size,used,pcent", str(mount_point)],
            text=True,
            capture_output=True,
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
    udevadm = _find_tool("udevadm")
    if udevadm:
        subprocess.run([udevadm, "settle"], check=False)

    for _ in range(50):  # ~5s total
        if os.path.exists(snap_path):
            return snap_path
        if os.path.exists(mapper_path):
            return mapper_path
        time.sleep(0.1)

    # Last attempt to create nodes directly.
    dmsetup = _find_tool("dmsetup")
    if dmsetup:
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
            [
                rsync, "-rlt", "--delete", "--no-owner",
                "--no-group", "--no-perms", f"{src}/", f"{dst}/",
            ],
            check=True,
        )
        return
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def mount_rw(dev: str, mount_point: Path, offset_override: int | None = None) -> None:
    _mount_device(dev, mount_point, readonly=False, offset_override=offset_override)


def get_partition_offset(dev: str) -> int | None:
    try:
        sfdisk = _find_tool("sfdisk") or "sfdisk"
        result = subprocess.run(
            [sfdisk, "-d", dev],
            text=True,
            capture_output=True,
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
            capture_output=True,
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
    partx = _find_tool("partx")
    if partx:
        subprocess.run([partx, "-a", dev], check=False)
    kpartx = _find_tool("kpartx")
    if kpartx:
        subprocess.run([kpartx, "-a", dev], check=False)
        # Try to read the mapping name from kpartx output (e.g. vg0-usb_sync_snap1).
        kp = subprocess.run([kpartx, "-l", dev], text=True, capture_output=True, check=False)
        for line in kp.stdout.splitlines():
            name = line.split()[0].strip() if line.split() else ""
            if name:
                mapper = f"/dev/mapper/{name}"
                if os.path.exists(mapper):
                    return mapper
    udevadm = _find_tool("udevadm")
    if udevadm:
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
        capture_output=True,
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

def _process_file(
    path: Path,
    st: os.stat_result,
    mount_root: Path,
    cfg,
    conn,
    raw_dir: Path,
    bydate_dir: Path,
    now: int,
    counters: dict,
) -> None:
    counters["scanned"] += 1
    rel = path.relative_to(mount_root)
    size = int(st.st_size)
    mtime = int(st.st_mtime)
    if size >= cfg.max_file_size:
        counters["skipped_large"] += 1
        return

    stable = update_state(conn, str(rel), size, mtime, now)
    if stable < cfg.stable_scans:
        return

    if is_already_synced(conn, str(rel), size, mtime):
        return

    dt = datetime.fromtimestamp(mtime if cfg.bydate_use_file_time else now)
    date_path = bydate_dir / dt.strftime("%Y/%m/%d")

    raw_subdir = safe_join(raw_dir, rel.parent)
    name = rel.name
    stem = Path(name).stem
    suffix = Path(name).suffix
    collision = (raw_subdir / name).exists()
    if cfg.append_always:
        collision = True
    final_name = f"{stem}_{mtime}{suffix}" if collision else name

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
    counters["synced"] += 1
    log_every = counters.get("log_every", 0)
    if log_every > 0 and counters["synced"] % log_every == 0:
        log(f"sync progress: synced={counters['synced']} scanned={counters['scanned']}")


def check_mirror_free_space(cfg) -> bool:
    try:
        usage = shutil.disk_usage(str(cfg.mirror_mount))
        free_mb = usage.free // (1024 * 1024)
        used_pct = int(usage.used * 100 / usage.total) if usage.total > 0 else 0
        if free_mb < cfg.mirror_free_min_mb:
            log(f"mirror free space low: {free_mb}MB < {cfg.mirror_free_min_mb}MB, skipping sync")
            return False
        if used_pct >= cfg.mirror_retention_trigger_pct:
            threshold = cfg.mirror_retention_trigger_pct
            log(f"mirror usage {used_pct}% >= {threshold}%, triggering retention")
            subprocess.run(
                ["/bin/systemctl", "start", "mirror-retention.service"],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
    except OSError as exc:
        log(f"mirror free space check failed: {exc}")
    return True


def stable_and_copy(cfg, mount_root: Path, conn) -> None:
    if not check_mirror_free_space(cfg):
        return
    raw_dir = cfg.mirror_mount / "raw"
    bydate_dir = cfg.mirror_mount / "bydate"
    now = int(time.time())
    counters = {
        "scanned": 0,
        "synced": 0,
        "skipped_large": 0,
        "log_every": max(0, int(getattr(cfg, "sync_log_every", 0))),
    }
    selected_roots, scan_plan = select_scan_roots(cfg, mount_root)
    if scan_plan["selected"]:
        log(
            "sync plan: "
            f"depth={scan_plan['depth']} "
            f"top_dirs={scan_plan['top_dirs']} "
            f"hot={','.join(scan_plan['hot']) if scan_plan['hot'] else '-'} "
            f"audit={','.join(scan_plan['audit']) if scan_plan['audit'] else '-'}"
        )
    else:
        log(
            f"sync plan: depth={scan_plan['depth']}"
            f" top_dirs={scan_plan['top_dirs']} root-files-only"
        )

    try:
        # Always include files directly in root (non-recursive).
        for path, st in iter_root_files(mount_root):
            _process_file(path, st, mount_root, cfg, conn, raw_dir, bydate_dir, now, counters)

        for root in selected_roots:
            if not root.exists():
                continue
            for path, st in iter_files(root):
                _process_file(path, st, mount_root, cfg, conn, raw_dir, bydate_dir, now, counters)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    log(
        f"sync summary: scanned={counters['scanned']}"
        f" synced={counters['synced']}"
        f" skipped_large={counters['skipped_large']}"
    )


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

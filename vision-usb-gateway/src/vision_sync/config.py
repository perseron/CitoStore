import shlex
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Config:
    mirror_mount: Path
    state_dir: Path
    snapshot_name: str
    snapshot_mount: Path
    lvm_vg: str
    usb_lvs: list[str]
    usb_persist_dir: str
    usb_persist_backing: Path
    sync_change_detect: bool
    sync_manifest_path: Path
    sync_change_resume_scans: int
    stable_scans: int
    max_file_size: int
    copy_chunk: int
    append_always: bool
    bydate_use_file_time: bool
    sync_log_every: int
    sync_scan_depth: int
    sync_hot_dirs: int
    sync_cold_audit_dirs_per_run: int
    sync_dir_index_file: Path


def _parse_line(line: str):
    if "=" not in line:
        return None, None
    key, value = line.split("=", 1)
    return key.strip(), value.strip()


def _parse_value(value: str):
    if value.startswith("(") and value.endswith(")"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return shlex.split(inner)
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    return value


def parse_config_text(text: str) -> dict:
    data = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, value = _parse_line(line)
        if key is None:
            continue
        data[key] = _parse_value(value)
    return data


def load_config(path: str) -> dict:
    return parse_config_text(Path(path).read_text())


def get_config(path: str) -> Config:
    data = load_config(path)
    mirror_mount = Path(data.get("MIRROR_MOUNT", "/srv/vision_mirror"))
    state_dir = mirror_mount / ".state"
    snapshot_name = data.get("SYNC_SNAPSHOT_NAME", "usb_sync_snap")
    snapshot_mount = Path(data.get("SYNC_MOUNT", "/mnt/vision_snap"))
    lvm_vg = data.get("LVM_VG", "vg0")
    usb_lvs = data.get("USB_LVS", ["usb_0"])
    if isinstance(usb_lvs, str):
        usb_lvs = [usb_lvs]
    usb_persist_dir = data.get("USB_PERSIST_DIR", "aoi_settings")
    usb_persist_backing = Path(
        data.get("USB_PERSIST_BACKING", str(mirror_mount / ".state" / usb_persist_dir))
    )
    _truthy = ("1", "true", "yes", "on")
    sync_change_detect = (
        str(data.get("SYNC_CHANGE_DETECT", "false")).lower() in _truthy
    )
    sync_manifest_path = Path(
        data.get("SYNC_MANIFEST_FILE", str(mirror_mount / ".state" / "usb_sync.manifest"))
    )
    sync_change_resume_scans = int(
        data.get("SYNC_CHANGE_RESUME_SCANS", data.get("STABLE_SCAN_REQUIRED", "2"))
    )
    stable_scans = int(data.get("STABLE_SCAN_REQUIRED", "2"))
    max_file_size = int(data.get("MAX_FILE_SIZE_BYTES", str(4 * 1024 ** 3)))
    copy_chunk = int(data.get("COPY_CHUNK_BYTES", str(8 * 1024 ** 2)))
    append_always = (
        str(data.get("RAW_APPEND_ALWAYS", "false")).lower() in _truthy
    )
    bydate_use_file_time = (
        str(data.get("BYDATE_USE_FILE_TIME", "false")).lower() in _truthy
    )
    sync_log_every = int(data.get("SYNC_LOG_EVERY", "0"))
    sync_scan_depth = int(data.get("SYNC_SCAN_DEPTH", "1"))
    sync_hot_dirs = int(data.get("SYNC_HOT_DIRS", "1"))
    sync_cold_audit_dirs_per_run = int(data.get("SYNC_COLD_AUDIT_DIRS_PER_RUN", "1"))
    sync_dir_index_file = Path(
        data.get("SYNC_DIR_INDEX_FILE", str(mirror_mount / ".state" / "sync-dir-index.json"))
    )
    return Config(
        mirror_mount=mirror_mount,
        state_dir=state_dir,
        snapshot_name=snapshot_name,
        snapshot_mount=snapshot_mount,
        lvm_vg=lvm_vg,
        usb_lvs=usb_lvs,
        usb_persist_dir=usb_persist_dir,
        usb_persist_backing=usb_persist_backing,
        sync_change_detect=sync_change_detect,
        sync_manifest_path=sync_manifest_path,
        sync_change_resume_scans=sync_change_resume_scans,
        stable_scans=stable_scans,
        max_file_size=max_file_size,
        copy_chunk=copy_chunk,
        append_always=append_always,
        bydate_use_file_time=bydate_use_file_time,
        sync_log_every=sync_log_every,
        sync_scan_depth=sync_scan_depth,
        sync_hot_dirs=sync_hot_dirs,
        sync_cold_audit_dirs_per_run=sync_cold_audit_dirs_per_run,
        sync_dir_index_file=sync_dir_index_file,
    )

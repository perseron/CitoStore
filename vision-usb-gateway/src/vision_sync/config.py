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
    stable_scans: int
    max_file_size: int
    copy_chunk: int


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


def load_config(path: str) -> dict:
    data = {}
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, value = _parse_line(line)
        if key is None:
            continue
        data[key] = _parse_value(value)
    return data


def get_config(path: str) -> Config:
    data = load_config(path)
    mirror_mount = Path(data.get("MIRROR_MOUNT", "/srv/vision_mirror"))
    state_dir = mirror_mount / ".state"
    snapshot_name = data.get("SYNC_SNAPSHOT_NAME", "usb_sync_snap")
    snapshot_mount = Path(data.get("SYNC_MOUNT", "/mnt/vision_snap"))
    lvm_vg = data.get("LVM_VG", "vg0")
    stable_scans = int(data.get("STABLE_SCAN_REQUIRED", "2"))
    max_file_size = int(data.get("MAX_FILE_SIZE_BYTES", str(4 * 1024 ** 3)))
    copy_chunk = int(data.get("COPY_CHUNK_BYTES", str(8 * 1024 ** 2)))
    return Config(
        mirror_mount=mirror_mount,
        state_dir=state_dir,
        snapshot_name=snapshot_name,
        snapshot_mount=snapshot_mount,
        lvm_vg=lvm_vg,
        stable_scans=stable_scans,
        max_file_size=max_file_size,
        copy_chunk=copy_chunk,
    )
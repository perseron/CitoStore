import hashlib
import os
import time
from pathlib import Path
from typing import Iterator, Tuple


SKIP_DIRS = {"System Volume Information", "$RECYCLE.BIN"}


def iter_files(root: Path) -> Iterator[Tuple[Path, os.stat_result]]:
    for dirpath, dirnames, filenames in os.walk(root, topdown=True):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            try:
                st = p.stat()
            except FileNotFoundError:
                continue
            if not p.is_file():
                continue
            yield p, st


def safe_join(base: Path, rel: Path) -> Path:
    if rel.is_absolute():
        raise ValueError("absolute path not allowed")
    norm = (base / rel).resolve()
    if not str(norm).startswith(str(base.resolve())):
        raise ValueError("path traversal")
    return norm


def atomic_copy(src: Path, dest_dir: Path, final_name: str, chunk_size: int) -> Tuple[Path, str]:
    dest_dir.mkdir(parents=True, exist_ok=True)
    temp = dest_dir / f".{final_name}.{os.getpid()}.{int(time.time())}.tmp"
    h = hashlib.sha256()
    with src.open("rb") as fsrc, temp.open("wb") as fdst:
        while True:
            chunk = fsrc.read(chunk_size)
            if not chunk:
                break
            fdst.write(chunk)
            h.update(chunk)
        fdst.flush()
        os.fsync(fdst.fileno())
    digest = h.hexdigest()
    final = dest_dir / final_name
    os.rename(temp, final)
    return final, digest

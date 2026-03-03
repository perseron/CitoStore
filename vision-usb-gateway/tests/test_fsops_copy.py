import os
from pathlib import Path

from vision_sync.fsops import atomic_copy, compute_manifest, safe_join


def test_atomic_copy_creates_file(tmp_path: Path):
    src = tmp_path / "source.txt"
    src.write_text("hello world")
    dest_dir = tmp_path / "dest"

    result_path, digest = atomic_copy(src, dest_dir, "out.txt", 4096)

    assert result_path == dest_dir / "out.txt"
    assert result_path.read_text() == "hello world"
    assert len(digest) == 64  # sha256 hex


def test_atomic_copy_no_temp_leftover(tmp_path: Path):
    src = tmp_path / "source.bin"
    src.write_bytes(b"\x00" * 100)
    dest_dir = tmp_path / "dest"

    atomic_copy(src, dest_dir, "out.bin", 32)

    files = list(dest_dir.iterdir())
    assert len(files) == 1
    assert files[0].name == "out.bin"


def test_atomic_copy_creates_dest_dir(tmp_path: Path):
    src = tmp_path / "file.txt"
    src.write_text("data")
    dest_dir = tmp_path / "a" / "b" / "c"

    result_path, _ = atomic_copy(src, dest_dir, "file.txt", 4096)

    assert dest_dir.exists()
    assert result_path.exists()


def test_atomic_copy_consistent_digest(tmp_path: Path):
    src = tmp_path / "file.dat"
    content = b"consistent content"
    src.write_bytes(content)

    _, digest1 = atomic_copy(src, tmp_path / "d1", "f.dat", 4096)
    _, digest2 = atomic_copy(src, tmp_path / "d2", "f.dat", 4096)

    assert digest1 == digest2


def test_compute_manifest_empty_dir(tmp_path: Path):
    empty = tmp_path / "empty"
    empty.mkdir()
    # Empty dir with no files still produces a stable hash (sha256 of empty input)
    d1 = compute_manifest(empty)
    d2 = compute_manifest(empty)
    assert d1 == d2
    assert len(d1) == 64


def test_compute_manifest_nonexistent():
    assert compute_manifest(Path("/nonexistent/path")) == ""


def test_compute_manifest_deterministic(tmp_path: Path):
    root = tmp_path / "data"
    root.mkdir()
    (root / "a.txt").write_text("aaa")
    (root / "b.txt").write_text("bbb")

    d1 = compute_manifest(root)
    d2 = compute_manifest(root)
    assert d1 == d2
    assert len(d1) == 64


def test_compute_manifest_changes_on_content(tmp_path: Path):
    root = tmp_path / "data"
    root.mkdir()
    f = root / "file.txt"
    f.write_text("version1")
    d1 = compute_manifest(root)

    f.write_text("version2")
    # Touch to change mtime
    os.utime(f, (999, 999))
    d2 = compute_manifest(root)

    assert d1 != d2


def test_safe_join_normal(tmp_path: Path):
    base = tmp_path / "base"
    base.mkdir()
    result = safe_join(base, Path("sub/file.txt"))
    assert str(result).startswith(str(base.resolve()))


def test_safe_join_rejects_absolute():
    import pytest

    with pytest.raises(ValueError, match="absolute"):
        safe_join(Path("/base"), Path("/etc/passwd"))


def test_safe_join_rejects_traversal(tmp_path: Path):
    import pytest

    base = tmp_path / "base"
    base.mkdir()
    with pytest.raises(ValueError, match="traversal"):
        safe_join(base, Path("../../etc"))

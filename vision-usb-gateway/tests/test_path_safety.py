from pathlib import Path
import pytest

from vision_sync.fsops import safe_join


def test_safe_join_ok(tmp_path: Path):
    base = tmp_path / "base"
    base.mkdir()
    p = safe_join(base, Path("sub/file.txt"))
    assert str(p).startswith(str(base))


def test_safe_join_traversal(tmp_path: Path):
    base = tmp_path / "base"
    base.mkdir()
    with pytest.raises(ValueError):
        safe_join(base, Path("../evil"))
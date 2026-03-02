from pathlib import Path

from vision_sync.sync import (
    _find_tool,
    next_lv,
    read_manifest_state,
    write_manifest_state,
)


def test_next_lv_empty_list():
    assert next_lv("/dev/vg0/usb_0", "vg0", []) is None


def test_next_lv_single_returns_none():
    assert next_lv("/dev/vg0/usb_0", "vg0", ["usb_0"]) is None


def test_next_lv_wraps_around():
    result = next_lv("/dev/vg0/usb_1", "vg0", ["usb_0", "usb_1"])
    assert result == "/dev/vg0/usb_0"


def test_next_lv_advances():
    result = next_lv("/dev/vg0/usb_0", "vg0", ["usb_0", "usb_1", "usb_2"])
    assert result == "/dev/vg0/usb_1"


def test_next_lv_unknown_device():
    result = next_lv("/dev/vg0/unknown", "vg0", ["usb_0", "usb_1"])
    assert result == "/dev/vg0/usb_0"


def test_read_manifest_state_missing(tmp_path: Path):
    path = tmp_path / "missing.manifest"
    digest, count, mode = read_manifest_state(path)
    assert digest == ""
    assert count == 0
    assert mode == "active"


def test_read_manifest_state_legacy_single_line(tmp_path: Path):
    path = tmp_path / "legacy.manifest"
    path.write_text("abc123\n")
    digest, count, mode = read_manifest_state(path)
    assert digest == "abc123"
    assert count == 0
    assert mode == "active"


def test_write_and_read_manifest_state(tmp_path: Path):
    path = tmp_path / "state" / "test.manifest"
    write_manifest_state(path, "deadbeef", 5, "suspend")
    digest, count, mode = read_manifest_state(path)
    assert digest == "deadbeef"
    assert count == 5
    assert mode == "suspend"


def test_write_manifest_state_normalizes_mode(tmp_path: Path):
    path = tmp_path / "test.manifest"
    write_manifest_state(path, "abc", 1, "invalid_mode")
    _, _, mode = read_manifest_state(path)
    assert mode == "active"


def test_read_manifest_state_empty_file(tmp_path: Path):
    path = tmp_path / "empty.manifest"
    path.write_text("")
    digest, count, mode = read_manifest_state(path)
    assert digest == ""
    assert count == 0
    assert mode == "active"


def test_find_tool_returns_none_for_missing():
    result = _find_tool("nonexistent_tool_xyz_12345")
    assert result is None


def test_find_tool_with_custom_paths(tmp_path: Path):
    tool_dir = tmp_path / "bin"
    tool_dir.mkdir()
    tool = tool_dir / "mytool"
    tool.write_text("#!/bin/sh\n")
    result = _find_tool("mytool", search_paths=(str(tool_dir),))
    assert result == str(tool)

from pathlib import Path

from vision_sync.config import get_config, load_config, parse_config_text


def test_parse_simple_key_value():
    text = "KEY=value\nOTHER=123"
    cfg = parse_config_text(text)
    assert cfg["KEY"] == "value"
    assert cfg["OTHER"] == "123"


def test_parse_quoted_value():
    text = 'NAME="hello world"'
    cfg = parse_config_text(text)
    assert cfg["NAME"] == "hello world"


def test_parse_list_value():
    text = 'USB_LVS=(usb_0 usb_1 usb_2)'
    cfg = parse_config_text(text)
    assert cfg["USB_LVS"] == ["usb_0", "usb_1", "usb_2"]


def test_parse_empty_list():
    text = "USB_LVS=()"
    cfg = parse_config_text(text)
    assert cfg["USB_LVS"] == []


def test_parse_skips_comments_and_blanks():
    text = "# comment\n\nKEY=val\n  # another comment"
    cfg = parse_config_text(text)
    assert cfg == {"KEY": "val"}


def test_parse_skips_lines_without_equals():
    text = "no-equals-here\nKEY=val"
    cfg = parse_config_text(text)
    assert cfg == {"KEY": "val"}


def test_load_config_from_file(tmp_path: Path):
    conf = tmp_path / "test.conf"
    conf.write_text("MIRROR_MOUNT=/data\nLVM_VG=myvg\n")
    cfg = load_config(str(conf))
    assert cfg["MIRROR_MOUNT"] == "/data"
    assert cfg["LVM_VG"] == "myvg"


def test_get_config_defaults(tmp_path: Path):
    conf = tmp_path / "test.conf"
    conf.write_text("")
    cfg = get_config(str(conf))
    assert cfg.mirror_mount == Path("/srv/vision_mirror")
    assert cfg.lvm_vg == "vg0"
    assert cfg.stable_scans == 2
    assert cfg.max_file_size == 4 * 1024**3
    assert cfg.copy_chunk == 8 * 1024**2
    assert cfg.append_always is False
    assert cfg.bydate_use_file_time is False
    assert cfg.sync_scan_depth == 1
    assert cfg.sync_hot_dirs == 1


def test_get_config_custom_values(tmp_path: Path):
    conf = tmp_path / "test.conf"
    conf.write_text(
        "MIRROR_MOUNT=/mnt/data\n"
        "LVM_VG=testvg\n"
        'USB_LVS=(usb_a usb_b)\n'
        "STABLE_SCAN_REQUIRED=3\n"
        "RAW_APPEND_ALWAYS=true\n"
        "BYDATE_USE_FILE_TIME=1\n"
        "SYNC_SCAN_DEPTH=4\n"
        "SYNC_HOT_DIRS=2\n"
    )
    cfg = get_config(str(conf))
    assert cfg.mirror_mount == Path("/mnt/data")
    assert cfg.lvm_vg == "testvg"
    assert cfg.usb_lvs == ["usb_a", "usb_b"]
    assert cfg.stable_scans == 3
    assert cfg.append_always is True
    assert cfg.bydate_use_file_time is True
    assert cfg.sync_scan_depth == 4
    assert cfg.sync_hot_dirs == 2


def test_get_config_single_lv_string(tmp_path: Path):
    conf = tmp_path / "test.conf"
    conf.write_text("USB_LVS=usb_0\n")
    cfg = get_config(str(conf))
    assert cfg.usb_lvs == ["usb_0"]

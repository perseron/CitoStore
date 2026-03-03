import sys
from pathlib import Path

# Ensure the webui module can be imported even without its runtime dependencies
# by making vision_sync available via PYTHONPATH.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from vision_webui.server import (
    format_value,
    parse_duration_seconds,
    update_config_file,
    validate_config_updates,
)

# --- validate_config_updates ---


def test_validate_empty_updates():
    ok, err = validate_config_updates({})
    assert ok is True
    assert err == ""


def test_validate_valid_netbios_name():
    ok, _ = validate_config_updates({"NETBIOS_NAME": "MY-HOST"})
    assert ok is True


def test_validate_invalid_netbios_name_too_long():
    ok, err = validate_config_updates({"NETBIOS_NAME": "a" * 16})
    assert ok is False
    assert "NETBIOS_NAME" in err


def test_validate_invalid_netbios_name_empty():
    ok, err = validate_config_updates({"NETBIOS_NAME": ""})
    assert ok is False


def test_validate_valid_webui_port():
    ok, _ = validate_config_updates({"WEBUI_PORT": "8080"})
    assert ok is True


def test_validate_invalid_webui_port_zero():
    ok, err = validate_config_updates({"WEBUI_PORT": "0"})
    assert ok is False
    assert "range" in err.lower() or "WEBUI_PORT" in err


def test_validate_invalid_webui_port_too_high():
    ok, err = validate_config_updates({"WEBUI_PORT": "99999"})
    assert ok is False


def test_validate_invalid_webui_port_not_number():
    ok, err = validate_config_updates({"WEBUI_PORT": "abc"})
    assert ok is False


def test_validate_nas_enabled_valid():
    ok, _ = validate_config_updates({"NAS_ENABLED": "true"})
    assert ok is True
    ok, _ = validate_config_updates({"NAS_ENABLED": "false"})
    assert ok is True


def test_validate_nas_enabled_invalid():
    ok, err = validate_config_updates({"NAS_ENABLED": "yes"})
    assert ok is False


def test_validate_sync_scan_depth_range():
    ok, _ = validate_config_updates({"SYNC_SCAN_DEPTH": "1"})
    assert ok is True
    ok, _ = validate_config_updates({"SYNC_SCAN_DEPTH": "16"})
    assert ok is True
    ok, err = validate_config_updates({"SYNC_SCAN_DEPTH": "0"})
    assert ok is False
    ok, err = validate_config_updates({"SYNC_SCAN_DEPTH": "17"})
    assert ok is False


def test_validate_switch_window_format():
    ok, _ = validate_config_updates({"SWITCH_WINDOW_START": "8:00"})
    assert ok is True
    ok, _ = validate_config_updates({"SWITCH_WINDOW_START": "23:59"})
    assert ok is True
    ok, err = validate_config_updates({"SWITCH_WINDOW_START": "invalid"})
    assert ok is False


def test_validate_switch_delay_sec():
    ok, _ = validate_config_updates({"SWITCH_DELAY_SEC": "5"})
    assert ok is True
    ok, err = validate_config_updates({"SWITCH_DELAY_SEC": "11"})
    assert ok is False
    ok, err = validate_config_updates({"SWITCH_DELAY_SEC": "-1"})
    assert ok is False


def test_validate_boolean_fields():
    ok, _ = validate_config_updates({"BYDATE_USE_FILE_TIME": "true"})
    assert ok is True
    ok, err = validate_config_updates({"BYDATE_USE_FILE_TIME": "yes"})
    assert ok is False
    ok, _ = validate_config_updates({"RAW_APPEND_ALWAYS": "false"})
    assert ok is True


def test_validate_smb_bind_interface():
    ok, _ = validate_config_updates({"SMB_BIND_INTERFACE": "eth0"})
    assert ok is True
    ok, err = validate_config_updates({"SMB_BIND_INTERFACE": ""})
    assert ok is False


# --- parse_duration_seconds ---


def test_parse_duration_seconds_simple():
    assert parse_duration_seconds("30s") == 30.0


def test_parse_duration_seconds_minutes():
    assert parse_duration_seconds("2min") == 120.0


def test_parse_duration_seconds_hours():
    assert parse_duration_seconds("1h") == 3600.0


def test_parse_duration_seconds_combined():
    result = parse_duration_seconds("1h 30min 10s")
    assert result == 3600 + 1800 + 10


def test_parse_duration_seconds_microseconds():
    assert parse_duration_seconds("1000us") == 0.001


def test_parse_duration_seconds_no_unit_defaults_to_seconds():
    assert parse_duration_seconds("42") == 42.0


def test_parse_duration_seconds_unknown_unit():
    import pytest

    with pytest.raises(ValueError, match="unknown unit"):
        parse_duration_seconds("10xyz")


# --- update_config_file ---


def test_update_config_file_updates_existing_key():
    base = "KEY1=old\nKEY2=other\n"
    result = update_config_file(base, {"KEY1": "new"})
    assert "KEY1=new" in result
    assert "KEY2=other" in result


def test_update_config_file_adds_missing_key():
    base = "KEY1=val\n"
    result = update_config_file(base, {"NEW_KEY": "hello"})
    assert "KEY1=val" in result
    assert "NEW_KEY=hello" in result


def test_update_config_file_preserves_comments():
    base = "# important comment\nKEY=val\n"
    result = update_config_file(base, {"KEY": "new"})
    assert "# important comment" in result


def test_update_config_file_quotes_spaces():
    base = "KEY=old\n"
    result = update_config_file(base, {"KEY": "hello world"})
    assert 'KEY="hello world"' in result


# --- format_value ---


def test_format_value_plain():
    assert format_value("hello") == "hello"


def test_format_value_empty():
    assert format_value("") == '""'


def test_format_value_with_spaces():
    assert format_value("hello world") == '"hello world"'


def test_format_value_with_hash():
    result = format_value("value#comment")
    assert result.startswith('"')

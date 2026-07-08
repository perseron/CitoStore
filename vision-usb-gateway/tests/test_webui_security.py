from pathlib import Path

import pytest

from vision_webui import server


def test_setup_allowed_only_before_password_exists(tmp_path: Path, monkeypatch):
    pass_file = tmp_path / "webui.passwd"
    monkeypatch.setattr(server, "PASS_FILE", pass_file)
    assert server.setup_allowed() is True

    pass_file.write_text("{}", encoding="utf-8")
    # Once a password is configured, /setup must never reset it again.
    assert server.setup_allowed() is False


@pytest.mark.parametrize(
    "value",
    [
        "//nas/$(touch /tmp/pwn)",
        "//nas/`id`",
        "//nas/x;reboot",
        "//nas/x\nNAS_ENABLED=true",
        '//nas/x" ; id #',
        "//nas/x&&id",
        "//nas/x|id",
    ],
)
def test_shell_metacharacters_rejected(value):
    ok, err = server.validate_config_updates({"NAS_REMOTE": value})
    assert ok is False
    assert "unsafe characters" in err


def test_unvalidated_keys_are_now_validated():
    assert server.validate_config_updates({"NAS_REMOTE": "nas/vision"})[0] is False
    assert server.validate_config_updates({"NAS_MOUNT": "relative/path"})[0] is False
    assert server.validate_config_updates({"NAS_MOUNT": "/mnt/../etc"})[0] is False
    assert server.validate_config_updates({"USB_LV_SIZE": "100"})[0] is False
    assert server.validate_config_updates({"USB_LV_SIZE": "abcG"})[0] is False


def test_valid_values_accepted():
    updates = {
        "NAS_REMOTE": "//nas/vision",
        "NAS_MOUNT": "/mnt/nas",
        "USB_LV_SIZE": "100G",
        "NETBIOS_NAME": "CITOSTORE",
        "WEBUI_PORT": "80",
        "NAS_ENABLED": "true",
    }
    assert server.validate_config_updates(updates) == (True, "")


def test_format_value_refuses_unsafe_input():
    assert server.format_value("100G") == "100G"
    assert server.format_value("") == '""'
    with pytest.raises(ValueError):
        server.format_value("$(id)")


def test_update_config_file_round_trip():
    base = "NAS_REMOTE=//old/share\n# comment\nUSB_LV_SIZE=50G\n"
    out = server.update_config_file(base, {"NAS_REMOTE": "//nas/vision", "NAS_ENABLED": "true"})
    assert "NAS_REMOTE=//nas/vision" in out
    assert "NAS_ENABLED=true" in out
    assert "USB_LV_SIZE=50G" in out
    assert "//old/share" not in out

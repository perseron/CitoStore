import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

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
def test_config_shell_metacharacters_rejected(value):
    ok, err = server.validate_config_updates({"NAS_REMOTE": value})
    assert ok is False
    assert "unsafe characters" in err


def test_previously_unvalidated_keys_now_validated():
    assert server.validate_config_updates({"NAS_REMOTE": "nas/vision"})[0] is False
    assert server.validate_config_updates({"NAS_MOUNT": "relative/path"})[0] is False
    assert server.validate_config_updates({"NAS_MOUNT": "/mnt/../etc"})[0] is False
    assert server.validate_config_updates({"USB_LV_SIZE": "100"})[0] is False
    assert server.validate_config_updates({"USB_LV_SIZE": "abcG"})[0] is False


def test_valid_config_values_accepted():
    updates = {
        "NAS_REMOTE": "//nas/vision",
        "NAS_MOUNT": "/mnt/nas",
        "USB_LV_SIZE": "100G",
        "NETBIOS_NAME": "CITOSTORE",
        "WEBUI_PORT": "80",
        "NAS_ENABLED": "true",
    }
    assert server.validate_config_updates(updates) == (True, "")

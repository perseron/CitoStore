"""Regression tests for the 2026-10-01 audit fixes in the WebUI server."""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from vision_webui import server


@pytest.fixture
def state(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "STATE_DIR", tmp_path)
    monkeypatch.setattr(server, "SECRET_FILE", tmp_path / "webui.secret")
    monkeypatch.setattr(server, "SHADOW_CONF", tmp_path / "vision-gw.conf")
    monkeypatch.setattr(server, "log", lambda *a, **k: None)
    return tmp_path


class FakeHandler:
    """Just enough of a request handler for the auth checks."""

    def __init__(self, cookies: dict):
        self.headers = {"Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items())}


def is_admin(cookies: dict) -> bool:
    return server.WebHandler.is_authenticated(FakeHandler(cookies))


# --- an export (SMB-password) session must never be an admin session ---------

def test_admin_session_is_admin(state):
    assert is_admin({"session": server.make_session("admin")})


def test_export_session_copied_into_the_admin_cookie_is_refused(state):
    # Same secret, user "export": the signature alone used to be enough, so an
    # operator who knows only the SMB password could open /admin (and upload an
    # update package, which runs as root).
    token = server.make_session(server.EXPORT_SESSION_USER)
    assert server.validate_session(token)  # it IS a valid export session
    assert not is_admin({"session": token})


def test_no_or_garbage_session_is_refused(state):
    assert not is_admin({})
    assert not is_admin({"session": "not-a-token"})


# --- config import: only bash-safe KEY=value lines reach the sourced config ----

GOOD = """# Vision USB Gateway config
GATEWAY_HOME=/opt/vision-usb-gateway
USB_LVS=(usb_0 usb_1 usb_2)
USB_CONFIG="Config 1"
NAS_RSYNC_OPTS="-aH --partial --inplace --timeout=30"
SMB_PASS_HINT='literal $notexpanded'
ETH1_GATEWAY=
RETENTION_HI=90   # trailing comment
"""


def test_a_real_config_is_accepted_and_normalized():
    text, err = server.validate_import_config(GOOD.replace("\n", "\r\n"))
    assert err == ""
    assert "\r" not in text  # a Windows-saved file must not reach bash with CRs
    assert "USB_LVS=(usb_0 usb_1 usb_2)" in text


@pytest.mark.parametrize(
    "line",
    [
        "NAS_REMOTE=$(touch /tmp/pwn)",
        "NAS_REMOTE=`id`",
        'NAS_REMOTE="$(id)"',
        'NAS_REMOTE="x`id`"',
        "NAS_REMOTE=a b",          # bash runs "b" as a command
        "NAS_REMOTE=x;reboot",
        "rm -rf /",
        "lowercase=1",
        "NAS_REMOTE=x && id",
        "USB_LVS=(usb_0 $(id))",
    ],
)
def test_unsafe_lines_are_refused_with_their_line_number(line):
    text, err = server.validate_import_config(f"RETENTION_HI=90\n{line}\n")
    assert text == ""
    assert err.startswith("line 2 ")


def test_import_writes_only_the_shadow_never_last_good(state):
    class Req(FakeHandler):
        def __init__(self, body):
            super().__init__({})
            raw = json.dumps({"config": body}).encode()
            self.headers = {"Content-Length": str(len(raw))}
            import io
            self.rfile = io.BytesIO(raw)
            self.sent = None

        def send_json(self, payload, status=200):
            self.sent = (status, payload)

    last_good = state / "vision-gw.conf.last-good"
    last_good.write_text("RETENTION_HI=90\n", encoding="utf-8")
    req = Req("RETENTION_HI=80\r\nRETENTION_LO=70\r\n")
    server.WebHandler.handle_config_import(req)
    assert req.sent[0] == 200
    assert (state / "vision-gw.conf").read_text(encoding="utf-8") == "RETENTION_HI=80\nRETENTION_LO=70\n"
    # last-good is what health-check rolls back to; an import must not overwrite it.
    assert last_good.read_text(encoding="utf-8") == "RETENTION_HI=90\n"

    bad = Req("RETENTION_HI=$(reboot)\n")
    server.WebHandler.handle_config_import(bad)
    assert bad.sent[0] == 400
    assert (state / "vision-gw.conf").read_text(encoding="utf-8") == "RETENTION_HI=80\nRETENTION_LO=70\n"


# --- a refused update upload must show up in the history --------------------

def test_update_rejections_are_recorded(state):
    server.record_update_history("unknown", "rejected: missing manifest.json")
    server.record_update_history("pkg-1", "ok")
    history = json.loads((state / "update-history.json").read_text(encoding="utf-8"))
    assert [h["status"] for h in history] == ["rejected: missing manifest.json", "ok"]


def test_update_history_is_capped(state):
    for i in range(25):
        server.record_update_history(f"v{i}", "ok")
    history = json.loads((state / "update-history.json").read_text(encoding="utf-8"))
    assert len(history) == 20 and history[-1]["version"] == "v24"

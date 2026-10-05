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


# --- 2026-10-05 review -------------------------------------------------------------

def test_negative_or_bogus_content_length_is_refused_before_any_read():
    # read(-1) reads until the client closes: one such request (no login
    # needed) stalled the single-threaded server.
    import io
    for value in ("-1", "abc"):
        sent = []
        req = type("R", (), {})()
        req.headers = {"Content-Length": value}
        req.path = "/login"
        req.rfile = io.BytesIO(b"")
        req.send_error = lambda code, msg=None, *a: sent.append(code)
        req._do_post = lambda: server.WebHandler._do_post(req)
        server.WebHandler.do_POST(req)
        assert sent == [400]


def test_idle_connections_time_out():
    assert server.WebHandler.timeout and server.WebHandler.timeout <= 60


def test_static_pages_carry_the_security_headers(tmp_path, monkeypatch):
    import io
    (tmp_path / "index.html").write_text("<p>x</p>", encoding="utf-8")
    monkeypatch.setattr(server, "STATIC_DIR", tmp_path)
    headers = []
    req = type("R", (), {})()
    req.send_response = lambda code: None
    req.send_header = lambda k, v: headers.append(k)
    req.end_headers = lambda: None
    req.wfile = io.BytesIO()
    req._send_security_headers = lambda: server.WebHandler._send_security_headers(req)
    server.WebHandler.serve_static(req, "index.html", content_type="text/html")
    assert "Content-Security-Policy" in headers and "X-Frame-Options" in headers


def test_a_password_change_ends_the_other_sessions(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "STATE_DIR", tmp_path)
    monkeypatch.setattr(server, "SECRET_FILE", tmp_path / "webui.secret")
    old = server.make_session("admin")
    assert server.validate_session(old)
    req = type("R", (), {})()
    cookies = server.WebHandler.end_other_sessions(req)
    assert not server.validate_session(old)
    token = cookies[0].split(";")[0].split("=", 1)[1]
    assert server.validate_session(token) and cookies[1].startswith(f"csrf={server.make_csrf(token)};")


def test_the_smb_password_is_not_on_the_command_line(monkeypatch):
    seen = {}

    def fake(args, input_text=None, timeout=120, env=None):
        seen["args"], seen["env"] = args, env
        return 0, "", ""

    monkeypatch.setattr(server, "run_cmd", fake)
    monkeypatch.setattr(server, "load_config_text", lambda: "SMB_USER=smbuser\n")
    assert server.verify_smb_password("Secret-1")
    assert not any("Secret-1" in a for a in seen["args"])
    assert seen["env"]["PASSWD"] == "Secret-1"


def test_reads_run_alongside_a_long_change():
    # Single-threaded, every page froze during a resize/wipe/apply and behind
    # one idle connection. Changes stay one at a time.
    import threading
    assert issubclass(server.DualStackHTTPServer, server.ThreadingHTTPServer)
    assert isinstance(server.POST_LOCK, type(threading.Lock()))
    order = []
    req = type("R", (), {})()
    req._do_post = lambda: order.append("post")
    with server.POST_LOCK:
        t = threading.Thread(target=server.WebHandler.do_POST, args=(req,))
        t.start()
        t.join(0.2)
        assert order == []          # waits for the change in progress
    t.join(2)
    assert order == ["post"]

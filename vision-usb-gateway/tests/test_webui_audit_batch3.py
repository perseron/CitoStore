"""Regression tests for audit batch 3 (2026-10-01) in the WebUI server."""
import contextlib
import io
import json
import os
import stat
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
    monkeypatch.setattr(server, "PASS_FILE", tmp_path / "webui.passwd")
    monkeypatch.setattr(server, "log", lambda *a, **k: None)
    monkeypatch.setattr(server, "require_lock", contextlib.nullcontext)
    return tmp_path


class Req:
    def __init__(self, payload: dict):
        raw = json.dumps(payload).encode()
        self.headers = {"Content-Length": str(len(raw))}
        self.rfile = io.BytesIO(raw)
        self.sent = None

    def send_json(self, payload, status=200):
        self.sent = (status, payload)


# --- writes are atomic and private files never world-readable ----------------

def test_atomic_write_replaces_and_sets_mode(state):
    target = state / "f"
    target.write_text("old", encoding="utf-8")
    os.chmod(target, 0o644)
    server.atomic_write(target, "new", 0o600)
    assert target.read_text(encoding="utf-8") == "new"
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert not (state / "f.tmp").exists()


def test_a_truncated_session_secret_is_regenerated(state):
    # An empty key (power cut mid-write) would sign every session with a
    # guessable HMAC key: anyone could forge an admin cookie.
    (state / "webui.secret").write_bytes(b"")
    secret = server.ensure_secret()
    assert len(secret) == 32
    assert (state / "webui.secret").read_bytes() == secret


def test_config_save_writes_the_shadow_but_not_last_good(state):
    (state / "vision-gw.conf").write_text("GATEWAY_HOME=/x\nRETENTION_HI=90\n", encoding="utf-8")
    (state / "vision-gw.conf.last-good").write_text("GATEWAY_HOME=/x\nRETENTION_HI=90\n", encoding="utf-8")
    req = Req({"SYNC_INTERVAL_SEC": "30s"})
    server.WebHandler.handle_config_update(req)
    assert req.sent[0] == 200
    assert "SYNC_INTERVAL_SEC=30s" in (state / "vision-gw.conf").read_text(encoding="utf-8")
    # last-good is promoted by apply-shadow-config only after a clean apply.
    assert "SYNC_INTERVAL_SEC" not in (state / "vision-gw.conf.last-good").read_text(encoding="utf-8")


# --- USB LV size: one rule, checked before anything is destroyed -------------

@pytest.mark.parametrize("size", ["16G", "512M", "16g", "1G"])
def test_valid_lv_sizes(size):
    ok, err = server.validate_config_updates({"USB_LV_SIZE": size})
    assert ok, err


@pytest.mark.parametrize("size", ["", "0G", "4GB", "1.5G", "100", "4K", "4T", "4G;reboot", "$(id)G"])
def test_invalid_lv_sizes(size):
    ok, _ = server.validate_config_updates({"USB_LV_SIZE": size})
    assert not ok


def test_resize_rejects_a_bad_size_without_running_anything(state, monkeypatch):
    ran = []
    monkeypatch.setattr(server, "run_privileged", lambda args, **kw: (ran.append(args), (0, "", ""))[1])
    req = Req({"size": "4GB"})
    server.WebHandler.handle_maintenance(req, ["resize"])
    assert req.sent[0] == 400
    assert ran == []


def test_resize_passes_the_normalized_size(state, monkeypatch):
    ran = []
    monkeypatch.setattr(server, "run_privileged", lambda args, **kw: (ran.append(args), (0, "", ""))[1])
    req = Req({"size": " 16g "})
    server.WebHandler.handle_maintenance(req, ["resize"])
    assert req.sent[0] == 200
    assert ran[0][ran[0].index("--size") + 1] == "16G"
    assert "--update-config" in ran[0]


def test_rebalance_is_no_longer_a_webui_action(state, monkeypatch):
    # It erased every image and all settings behind a "rebalance allocation"
    # label, and a live re-layout of the in-use NVMe is unreliable.
    ran = []
    monkeypatch.setattr(server, "run_privileged", lambda args, **kw: (ran.append(args), (0, "", ""))[1])
    monkeypatch.setattr(server, "run_cmd", lambda args, **kw: (ran.append(args), (0, "", ""))[1])
    req = Req({})
    server.WebHandler.handle_maintenance(req, ["rebalance"])
    assert req.sent[0] == 400
    assert ran == []
    html = (Path(server.__file__).parent / "static" / "index.html").read_text(encoding="utf-8")
    assert 'id="rebalance"' not in html


# --- password changes report every step that fails ---------------------------

def _password_req(pw="Secret-123"):
    return Req({"password": pw, "confirm": pw})


def test_smb_password_reports_a_failed_unix_password(state, monkeypatch):
    monkeypatch.setattr(server, "load_config_text", lambda: "SMB_USER=smbuser\n")

    def fake(args, **kw):
        return (1, "", "chpasswd: user unknown") if args[0].endswith("chpasswd") else (0, "", "")

    monkeypatch.setattr(server, "run_privileged", fake)
    req = _password_req()
    server.WebHandler.handle_smb_password(req)
    assert req.sent[0] == 500
    assert "mirror FTP" in req.sent[1]["error"]
    creds = state / "smb_unix.creds"
    assert stat.S_IMODE(creds.stat().st_mode) == 0o600


def test_smb_password_reports_a_failed_enable(state, monkeypatch):
    monkeypatch.setattr(server, "load_config_text", lambda: "SMB_USER=smbuser\n")

    def fake(args, **kw):
        return (1, "", "failed") if args[:2] == ["/usr/bin/smbpasswd", "-e"] else (0, "", "")

    monkeypatch.setattr(server, "run_privileged", fake)
    req = _password_req()
    server.WebHandler.handle_smb_password(req)
    assert req.sent[0] == 500


def test_ftp_password_for_a_user_not_created_yet_is_stored_only(state, monkeypatch):
    monkeypatch.setattr(server, "load_config_text", lambda: "FTP_USER=no-such-user-xyz\n")
    ran = []
    monkeypatch.setattr(server, "run_privileged", lambda args, **kw: (ran.append(args), (0, "", ""))[1])
    req = _password_req()
    server.WebHandler.handle_ftp_password(req)
    assert req.sent[0] == 200
    assert ran == []
    assert (state / "ftp.creds").read_text(encoding="utf-8") == "password=Secret-123\n"


def test_ftp_password_failure_is_reported(state, monkeypatch):
    monkeypatch.setattr(server, "load_config_text", lambda: "FTP_USER=root\n")  # exists everywhere
    monkeypatch.setattr(server, "run_privileged", lambda args, **kw: (1, "", "chpasswd failed"))
    req = _password_req()
    server.WebHandler.handle_ftp_password(req)
    assert req.sent[0] == 500


# --- a provisioning bundle's config is checked before anything sources it ----

def _bundle(tmp_path, conf_text, name="./etc/vision-gw.conf"):
    import tarfile
    src = tmp_path / "vision-gw.conf"
    src.write_text(conf_text, encoding="utf-8")
    out = tmp_path / "b.citostore"
    with tarfile.open(out, "w:gz") as tar:
        tar.add(src, arcname=name)
    return out


def test_a_plain_bundle_config_is_accepted(tmp_path):
    b = _bundle(tmp_path, "GATEWAY_HOME=/opt/x\nUSB_LVS=(usb_0 usb_1 usb_2)\nUSB_LV_SIZE=16G\n")
    assert server.bundle_config_error(b) == ""


@pytest.mark.parametrize("line", ["USB_LV_SIZE=$(reboot)", "NETBIOS_NAME=`id`", "X=a b"])
def test_a_bundle_config_that_would_run_code_is_refused(tmp_path, line):
    b = _bundle(tmp_path, f"GATEWAY_HOME=/opt/x\n{line}\n")
    assert "bundle config rejected" in server.bundle_config_error(b)


def test_a_bundle_without_config_or_not_a_bundle_is_refused(tmp_path):
    assert server.bundle_config_error(_bundle(tmp_path, "A=1\n", name="./etc/other")) == "bundle missing vision-gw.conf"
    junk = tmp_path / "junk.citostore"
    junk.write_bytes(b"not a tar")
    assert "invalid bundle" in server.bundle_config_error(junk)


def test_plan_never_runs_on_a_rejected_bundle(state, tmp_path, monkeypatch):
    import tarfile
    src = tmp_path / "conf"
    src.write_text("GATEWAY_HOME=/opt/x\nUSB_LV_SIZE=$(reboot)\n", encoding="utf-8")
    raw_path = tmp_path / "raw.citostore"
    with tarfile.open(raw_path, "w:gz") as tar:
        tar.add(src, arcname="./etc/vision-gw.conf")
    stage = tmp_path / "stage"
    monkeypatch.setattr(server, "PROVISION_STAGE", stage)
    monkeypatch.setattr(server, "BUNDLE_STAGED", stage / "bundle.citostore")
    ran = []
    monkeypatch.setattr(server, "run_cmd", lambda args, **kw: (ran.append(args), (0, "{}", ""))[1])

    class BinReq(Req):
        def __init__(self, raw: bytes):
            self.headers = {"Content-Length": str(len(raw))}
            self.rfile = io.BytesIO(raw)
            self.sent = None

    req = BinReq(raw_path.read_bytes())
    server.WebHandler.handle_bundle_plan(req)
    assert req.sent[0] == 400
    assert ran == []
    assert not (stage / "bundle.citostore").exists()


# --- Set Time reports an RTC write that failed -------------------------------

def test_set_time_reports_a_failed_rtc_write(state, monkeypatch):
    monkeypatch.setattr(server, "set_system_time", lambda value: (0, "", ""))
    monkeypatch.setattr(server, "run_privileged", lambda args, **kw: (1, "", "hwclock: ioctl failed"))
    req = Req({"time": "2026-10-01 10:00:00"})
    server.WebHandler.handle_time(req)
    assert req.sent[0] == 500
    assert "RTC" in req.sent[1]["error"]


def test_set_time_ok_when_the_rtc_took_it(state, monkeypatch):
    monkeypatch.setattr(server, "set_system_time", lambda value: (0, "", ""))
    monkeypatch.setattr(server, "run_privileged", lambda args, **kw: (0, "", ""))
    req = Req({"time": "2026-10-01 10:00:00"})
    server.WebHandler.handle_time(req)
    assert req.sent == (200, {"ok": True})


# --- boot-time health findings stay visible ----------------------------------

def _health(tmp_path, monkeypatch, live, boot):
    live_f, boot_f = tmp_path / "health.json", tmp_path / "boot.json"
    if live is not None:
        live_f.write_text(json.dumps(live), encoding="utf-8")
    if boot is not None:
        boot_f.write_text(json.dumps(boot), encoding="utf-8")
    monkeypatch.setattr(server, "HEALTH_FILES", (live_f, tmp_path / "none.json"))
    monkeypatch.setattr(server, "BOOT_HEALTH_FILE", boot_f)
    return server.read_health()


def test_boot_findings_survive_the_monitors_rewrite(state, tmp_path, monkeypatch):
    h = _health(tmp_path, monkeypatch,
                {"status": "ok", "issues": [], "ts": "t"},
                {"status": "warn", "issues": ["usb_1: aoi_settings folder was missing; restored"], "ts": "b"})
    assert h["status"] == "warn"
    assert h["issues"] == ["boot: usb_1: aoi_settings folder was missing; restored"]


def test_live_error_is_not_downgraded_by_boot_warning(state, tmp_path, monkeypatch):
    h = _health(tmp_path, monkeypatch,
                {"status": "error", "issues": ["gadget down"], "ts": "t"},
                {"status": "warn", "issues": ["fsck.fat repaired the FAT on usb_0"], "ts": "b"})
    assert h["status"] == "error"
    assert h["issues"] == ["gadget down", "boot: fsck.fat repaired the FAT on usb_0"]


def test_clean_boot_leaves_live_health_alone(state, tmp_path, monkeypatch):
    live = {"status": "ok", "issues": [], "ts": "t"}
    assert _health(tmp_path, monkeypatch, live, {"status": "ok", "issues": [], "ts": "b"}) == live
    assert _health(tmp_path, monkeypatch, live, None) == live

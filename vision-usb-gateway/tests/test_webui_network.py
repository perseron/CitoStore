import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from vision_webui import server

STATIC = ("eth0", "manual", "10.10.10.50", "24", "", "")
DHCP = ("eth0", "auto", "", "24", "", "")
DHCP_TIMEOUT = "Error: Connection activation failed: IP configuration could not be reserved"


@pytest.fixture
def nm(tmp_path, monkeypatch):
    """Stub NetworkManager: eth0 has an active connection; `up` answers per test."""
    state = tmp_path / "network.json"
    calls = []
    up_result = {"rc": 0, "err": ""}

    def fake_run_cmd(args, input_text=None, timeout=120):
        calls.append(args)
        if "up" in args:
            return up_result["rc"], "", up_result["err"]
        return 0, "", ""

    monkeypatch.setattr(server, "run_cmd", fake_run_cmd)
    monkeypatch.setattr(server, "get_nm_active_connection", lambda iface: "Wired connection 1")
    monkeypatch.setattr(server, "NETWORK_STATE", state)
    return state, calls, up_result


def test_profile_changes_are_never_written_to_disk(nm):
    # A saved modify landed on the eMMC on the overlay-off first boot after a
    # flash, and the static IP then outlived network.json.
    _, calls, _ = nm
    for args in (STATIC, DHCP):
        calls.clear()
        server.apply_network_config(*args)
        modify = [c for c in calls if "modify" in c]
        assert modify and all(c[:4] == ["nmcli", "connection", "modify", "--temporary"] for c in modify)


def test_activation_is_bounded(nm):
    _, calls, _ = nm
    server.apply_network_config(*STATIC)
    assert ["nmcli", "--wait", "20", "connection", "up", "Wired connection 1"] in calls


def test_static_is_applied_and_saved(nm):
    state, _, _ = nm
    ok, message = server.apply_and_save_network(*STATIC)
    assert (ok, message) == (True, "")
    saved = json.loads(state.read_text(encoding="utf-8"))
    assert (saved["method"], saved["address"], saved["prefix"]) == ("manual", "10.10.10.50", "24")


def test_dhcp_is_saved_even_when_no_dhcp_server_answers(nm):
    # Direct laptop link: activation times out. Refusing to save left the unit
    # stuck on its static address with no way back from the WebUI.
    state, _, up = nm
    state.write_text(json.dumps({"interface": "eth0", "method": "manual", "address": "10.10.10.50"}))
    up["rc"], up["err"] = 4, DHCP_TIMEOUT
    ok, message = server.apply_and_save_network(*DHCP)
    assert ok
    assert "restart" in message
    assert json.loads(state.read_text(encoding="utf-8"))["method"] == "auto"


def test_dhcp_is_saved_with_no_active_connection(nm, monkeypatch):
    state, _, _ = nm
    monkeypatch.setattr(server, "get_nm_active_connection", lambda iface: "")
    ok, message = server.apply_and_save_network(*DHCP)
    assert ok and message
    assert json.loads(state.read_text(encoding="utf-8"))["method"] == "auto"


def test_a_failed_static_apply_is_not_saved(nm):
    # Unlike DHCP, a static address that could not be applied must not be
    # re-applied at every boot behind the operator's back.
    state, _, up = nm
    previous = json.dumps({"interface": "eth0", "method": "auto"})
    state.write_text(previous)
    up["rc"], up["err"] = 4, "Error: no carrier"
    ok, message = server.apply_and_save_network(*STATIC)
    assert not ok
    assert "carrier" in message
    assert state.read_text() == previous


def test_invalid_static_parameters_are_refused_and_not_saved(nm):
    state, calls, _ = nm
    ok, message = server.apply_and_save_network("eth0", "manual", "10.10.10.999", "24", "", "")
    assert not ok
    assert "invalid" in message
    assert not state.exists()
    assert not [c for c in calls if "modify" in c]

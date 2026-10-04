"""Base network (eth0) setting in the WebUI: validated, saved to network.json,
applied out of band by scripts/apply-network.sh two seconds after the reply."""
import contextlib
import io
import json
import sys
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from vision_webui import server

CFG = {"MDNS_INTERFACE": "eth0", "ETH1_ENABLED": "true", "ETH1_ADDRESS": "192.168.100.1", "ETH1_PREFIX": "24"}
STATIC = {"method": "manual", "address": "192.168.5.20", "prefix": "24", "gateway": "192.168.5.1", "dns": "192.168.5.1, 8.8.8.8"}


def check(data, **cfg):
    return server.validate_network({**CFG, **cfg}, data)


def test_dhcp_record_and_the_interface_is_never_the_clients():
    # The form's free-text interface field let "eth1" rewrite the AOI link.
    error, record = check({"method": "auto", "interface": "eth1", "address": "1.2.3.4"})
    assert error == ""
    assert record == {"interface": "eth0", "method": "auto", "address": "", "prefix": "", "gateway": "", "dns": ""}


def test_static_record_is_normalized():
    error, record = check(STATIC)
    assert error == ""
    assert record == {"interface": "eth0", "method": "manual", "address": "192.168.5.20", "prefix": "24",
                      "gateway": "192.168.5.1", "dns": "192.168.5.1,8.8.8.8"}


@pytest.mark.parametrize("change, part", [
    ({"method": "shared"}, "auto (DHCP) or manual"),
    ({"address": "192.168.5.999"}, "IPv4 address and a prefix"),
    ({"address": "fe80::5"}, "IPv4 address and a prefix"),
    ({"prefix": "33"}, "IPv4 address and a prefix"),
    ({"prefix": ""}, "IPv4 address and a prefix"),
    ({"address": "192.168.5.0", "gateway": ""}, "network or broadcast"),
    ({"address": "192.168.5.255", "gateway": ""}, "network or broadcast"),
    ({"address": "127.0.0.5", "gateway": ""}, "not a usable host"),
    ({"address": "169.254.1.1", "prefix": "16", "gateway": ""}, "not a usable host"),
    ({"gateway": "10.0.0.1"}, "not another host"),
    ({"gateway": "192.168.5.20"}, "not another host"),
    ({"dns": "1.1.1.1,dns.example"}, "DNS servers"),
    ({"address": "192.168.100.20", "gateway": "", "dns": ""}, "overlaps the AOI link"),
])
def test_values_the_unit_cannot_use_are_refused(change, part):
    error, record = check({**STATIC, **change})
    assert part in error and record == {}


def test_the_aoi_subnet_is_free_while_eth1_is_off():
    error, _ = check({**STATIC, "address": "192.168.100.20", "gateway": "", "dns": ""}, ETH1_ENABLED="false")
    assert error == ""


def test_a_static_ip_in_the_direct_link_subnet_is_allowed():
    # mdns-apply-mode handles it (never serves DHCP with a fixed IP).
    assert check({"method": "manual", "address": "10.10.10.5", "prefix": "24"})[0] == ""


# --- the handler ------------------------------------------------------------------

class Conn:
    def __init__(self, local):
        self.local = local

    def getsockname(self):
        return (self.local, 80)


class Req:
    def __init__(self, payload, local):
        raw = json.dumps(payload).encode()
        self.headers = {"Content-Length": str(len(raw))}
        self.rfile = io.BytesIO(raw)
        self.connection = Conn(local)
        self.sent = None
        for name in ("local_address", "came_in_on"):
            setattr(self, name, types.MethodType(getattr(server.WebHandler, name), self))
        self.admin_url = server.WebHandler.admin_url

    def send_json(self, payload, status=200):
        self.sent = (status, payload)


@pytest.fixture
def unit(tmp_path, monkeypatch):
    """eth0 at 10.10.10.1 (a direct laptop link); systemd-run answers per test."""
    calls = []
    result = {"rc": 0, "err": ""}
    nets = {"eth0": ["10.10.10.1/24"], "eth1": ["192.168.100.1/24"]}
    conf = "\n".join(f"{k}={v}" for k, v in {**CFG, "NETBIOS_NAME": "AOI1", "WEBUI_PORT": "80"}.items())

    def fake_run_cmd(args, input_text=None, timeout=120):
        calls.append(args)
        return result["rc"], "", result["err"]

    monkeypatch.setattr(server, "run_cmd", fake_run_cmd)
    monkeypatch.setattr(server, "run_privileged", lambda *a, **k: pytest.fail("never applied in the request"))
    monkeypatch.setattr(server, "iface_ipv4", lambda iface: [server.ipaddress.ip_interface(n) for n in nets[iface]])
    monkeypatch.setattr(server, "load_config_text", lambda: conf)
    monkeypatch.setattr(server, "get_gateway_home", lambda: "/gw")
    monkeypatch.setattr(server, "NETWORK_STATE", tmp_path / "network.json")
    monkeypatch.setattr(server, "NETWORK_RESULT", tmp_path / "result.json")
    monkeypatch.setattr(server, "log", lambda *a, **k: None)
    monkeypatch.setattr(server, "require_lock", contextlib.nullcontext)
    return tmp_path / "network.json", calls, result


def post(payload, local="10.10.10.1"):
    req = Req(payload, local)
    server.WebHandler.handle_network(req)
    return req.sent


def test_saved_then_applied_out_of_band(unit):
    state, calls, _ = unit
    status, reply = post(STATIC)
    assert status == 200 and reply["ok"]
    assert json.loads(state.read_text())["address"] == "192.168.5.20"
    assert calls == [["systemd-run", "--quiet", "--collect", "--on-active=2",
                      "--timer-property=AccuracySec=100ms", "--unit=vision-network-apply",
                      "/gw/scripts/apply-network.sh"]]


def test_over_the_changing_address_the_page_is_sent_to_the_new_one(unit):
    _, _, _ = unit
    status, reply = post(STATIC, local="::ffff:10.10.10.1")
    assert reply["reconnect"] == "http://192.168.5.20/admin"


def test_same_address_or_another_port_needs_no_reconnect(unit):
    assert "reconnect" not in post({**STATIC, "address": "10.10.10.1", "gateway": "", "dns": ""})[1]
    assert "reconnect" not in post(STATIC, local="192.168.100.1")[1]


def test_static_to_dhcp_over_eth0_says_where_to_find_the_unit(unit):
    state, _, _ = unit
    state.write_text(json.dumps({"method": "manual", "address": "10.10.10.1", "prefix": "24"}))
    _, reply = post({"method": "auto"})
    assert reply["reconnect"] == ""
    assert reply["hint"] == "http://AOI1.local/admin"
    assert reply["direct"] == "http://10.10.10.1/admin"


def test_dhcp_to_dhcp_changes_nothing_so_no_reconnect(unit):
    _, reply = post({"method": "auto"})
    assert "reconnect" not in reply


def test_invalid_input_is_neither_saved_nor_applied(unit):
    state, calls, _ = unit
    status, reply = post({**STATIC, "address": "192.168.100.7", "gateway": ""})
    assert status == 400 and "AOI link" in reply["error"]
    assert not state.exists() and calls == []


def test_a_change_still_being_applied_is_reported(unit):
    _, _, result = unit
    result["rc"], result["err"] = 1, "Unit vision-network-apply.service was already loaded"
    status, reply = post(STATIC)
    assert status == 500 and "still be in progress" in reply["error"]


def test_get_shows_the_saved_setting_not_the_shared_profile(unit, monkeypatch):
    state, _, _ = unit
    cfg = server.parse_config(server.load_config_text())
    shown = server.get_network_setting(cfg)
    assert (shown["method"], shown["address"], shown["live"]) == ("auto", "", "10.10.10.1/24")
    state.write_text(json.dumps({"method": "manual", "address": "192.168.5.20", "prefix": "24", "gateway": "192.168.5.1"}))
    (state.parent / "result.json").write_text(json.dumps({"ok": False, "message": "x", "ts": 5}))
    shown = server.get_network_setting(cfg)
    assert (shown["method"], shown["address"], shown["gateway"]) == ("manual", "192.168.5.20/24", "192.168.5.1")
    assert shown["last_apply"] == {"ok": False, "message": "x", "ts": 5}


def test_import_refuses_an_eth1_the_unit_cannot_use(unit, monkeypatch, tmp_path):
    monkeypatch.setattr(server, "STATE_DIR", tmp_path)
    monkeypatch.setattr(server, "SHADOW_CONF", tmp_path / "vision-gw.conf")
    req = Req({"config": "ETH1_ENABLED=true\nETH1_ADDRESS=10.10.10.7\n"}, "10.10.10.1")
    server.WebHandler.handle_config_import(req)
    assert req.sent[0] == 400 and "overlaps" in req.sent[1]["error"]
    assert not (tmp_path / "vision-gw.conf").exists()

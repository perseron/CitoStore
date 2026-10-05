"""NVMe SMART in the WebUI status: what nvme-health.sh cached, as shown."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from vision_webui import server

# What nvme-cli 2.4 wrote on the unit (WD SN850X), plus nvme-health.sh's verdict.
CACHE = {
    "status": "ok", "device": "/dev/nvme0n1", "ts": "2026-10-05T09:14:45+02:00",
    "health": "warn", "issues": [["warn", "NVMe wear 92% of its rated write endurance - plan to replace the SSD"]],
    "smart": {
        "critical_warning": 0, "temperature": 303, "avail_spare": 100, "spare_thresh": 10,
        "percent_used": 92, "data_units_written": "6,226,522", "power_on_hours": "20",
        "unsafe_shutdowns": "119", "media_errors": "0",
    },
}


def show(tmp_path, monkeypatch, payload):
    cache = tmp_path / "vision-nvme.json"
    cache.write_text(json.dumps(payload), encoding="utf-8")
    monkeypatch.setattr(server, "STATE_DIR", tmp_path / "state")
    real_path = server.Path
    monkeypatch.setattr(server, "Path", lambda p: cache if p == "/run/vision-nvme.json" else real_path(p))
    return server.get_nvme_smart()


def test_wear_is_read_from_nvme_clis_key(tmp_path, monkeypatch):
    # nvme-cli's JSON says percent_used; percentage_used was read, never shown.
    shown = show(tmp_path, monkeypatch, CACHE)
    assert shown["percentage_used"] == 92


def test_counters_with_thousands_separators_are_numbers(tmp_path, monkeypatch):
    shown = show(tmp_path, monkeypatch, CACHE)
    assert (shown["power_on_hours"], shown["unsafe_shutdowns"], shown["media_errors"]) == (20, 119, 0)
    assert shown["data_units_written_tb"] == 3.19
    assert (shown["available_spare"], shown["spare_threshold"]) == (100, 10)
    assert shown["temperature_c"] == 29.9


def test_the_units_verdict_is_shown(tmp_path, monkeypatch):
    shown = show(tmp_path, monkeypatch, CACHE)
    assert shown["health"] == "warn"
    assert shown["issues"] == ["NVMe wear 92% of its rated write endurance - plan to replace the SSD"]


def test_no_smart_is_an_error(tmp_path, monkeypatch):
    shown = show(tmp_path, monkeypatch, {"status": "error", "error": "SMART log could not be read"})
    assert shown == {"error": "SMART log could not be read", "health": "error"}

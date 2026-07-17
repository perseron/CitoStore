import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from vision_webui import server

TIME = "2026-07-17 08:30:00"
RACE_ERR = "Failed to set time: Previous request is not finished, refusing."


def record_run_cmd(monkeypatch, responder):
    """Swap run_cmd for a recorder, returning the list of argv it was called with."""
    calls = []

    def fake_run_cmd(args, input_text=None, timeout=120):
        calls.append(args)
        return responder(args, calls)

    monkeypatch.setattr(server, "run_cmd", fake_run_cmd)
    monkeypatch.setattr(server, "TIME_SET_RETRY_SEC", 0)
    return calls


def set_time_calls(calls):
    return [c for c in calls if c[1:2] == ["set-time"]]


def test_ntp_is_disabled_before_setting_the_clock(monkeypatch):
    calls = record_run_cmd(monkeypatch, lambda args, _: (0, "", ""))

    code, _, _ = server.set_system_time(TIME)

    assert code == 0
    # timedatectl refuses set-time outright while timesyncd owns the clock, so
    # the handoff must come first, not alongside.
    assert calls[0] == ["/usr/bin/timedatectl", "set-ntp", "false"]
    assert calls[1] == ["/usr/bin/timedatectl", "set-time", TIME]


def test_set_time_retries_the_set_ntp_race(monkeypatch):
    def responder(args, calls):
        if args[1] == "set-time" and len(set_time_calls(calls)) < 3:
            return 1, "", RACE_ERR
        return 0, "", ""

    calls = record_run_cmd(monkeypatch, responder)

    code, _, _ = server.set_system_time(TIME)

    assert code == 0
    assert len(set_time_calls(calls)) == 3


def test_set_time_gives_up_on_a_wedged_race(monkeypatch):
    calls = record_run_cmd(monkeypatch, lambda args, _: (1, "", RACE_ERR))

    code, _, err = server.set_system_time(TIME)

    assert code == 1
    assert err == RACE_ERR
    # Bounded: a permanently stuck timedated must not hang the request thread.
    assert len(set_time_calls(calls)) == server.TIME_SET_ATTEMPTS


def test_a_real_error_is_not_retried(monkeypatch):
    def responder(args, _):
        if args[1] == "set-time":
            return 1, "", "Failed to parse time specification"
        return 0, "", ""

    calls = record_run_cmd(monkeypatch, responder)

    code, _, err = server.set_system_time("nonsense")

    assert code == 1
    assert "parse" in err
    # A bad time is not the race; spinning on it just delays the error.
    assert len(set_time_calls(calls)) == 1

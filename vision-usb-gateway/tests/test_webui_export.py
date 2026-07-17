import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from vision_webui import server


@pytest.fixture
def roots(tmp_path, monkeypatch):
    mirror = tmp_path / "mirror"
    usb = tmp_path / "usb"
    (mirror / "raw" / "2026").mkdir(parents=True)
    (mirror / ".state").mkdir()
    (mirror / ".state" / "ftp.creds").write_text("secret", encoding="utf-8")
    (mirror / "raw" / "2026" / "img.png").write_text("x", encoding="utf-8")
    usb.mkdir()
    (tmp_path / "outside.txt").write_text("do not reach me", encoding="utf-8")
    monkeypatch.setattr(server, "EXPORT_ROOTS", {"mirror": mirror, "usb": usb})
    return tmp_path, mirror, usb


@pytest.mark.parametrize(
    "rel",
    [
        "..",
        "../outside.txt",
        "raw/../../outside.txt",
        "raw/2026/../../../outside.txt",
        "/etc/shadow",
        "/srv/vision_mirror/.state",
    ],
)
def test_paths_outside_the_root_are_refused(roots, rel):
    with pytest.raises(ValueError):
        server.resolve_export_path("mirror", rel)


def test_state_is_unreachable(roots):
    # It holds the FTP/NAS/WebUI secrets and the Samba passdb; an earlier audit
    # found them readable over SMB. The file manager must not reopen that hole.
    for rel in (".state", ".state/ftp.creds"):
        with pytest.raises(ValueError):
            server.resolve_export_path("mirror", rel)


def test_state_is_not_listed(roots):
    listing = server.list_export_dir("mirror", "")
    assert [e["name"] for e in listing["entries"]] == ["raw"]


def test_a_symlink_cannot_escape_the_root(roots):
    _, mirror, _ = roots
    try:
        (mirror / "escape").symlink_to(mirror.parent / "outside.txt")
    except OSError:
        pytest.skip("symlinks not permitted on this platform")
    with pytest.raises(ValueError):
        server.resolve_export_path("mirror", "escape")


def test_unknown_root_is_refused(roots):
    with pytest.raises(ValueError):
        server.resolve_export_path("etc", "")


def test_ordinary_paths_resolve(roots):
    _, mirror, _ = roots
    assert server.resolve_export_path("mirror", "raw/2026") == (mirror / "raw" / "2026").resolve()
    assert server.resolve_export_path("mirror", "") == mirror.resolve()


def test_mirror_is_reported_read_only_and_usb_writable(roots):
    assert server.list_export_dir("mirror", "")["writable"] is False
    assert server.list_export_dir("usb", "")["writable"] is True


def test_copy_refuses_a_source_outside_the_roots(roots, monkeypatch):
    monkeypatch.setattr(server, "usb_copy_running", lambda: False)
    # Raised, not returned: handle_usb_copy turns it into a 400. Letting it
    # escape start_usb_copy means a bad path can never be mistaken for a rsync
    # argument by a future caller that forgets to check the status.
    with pytest.raises(ValueError):
        server.start_usb_copy([{"root": "mirror", "path": "../outside.txt"}], "")


def test_copy_refuses_while_one_is_running(roots, monkeypatch):
    monkeypatch.setattr(server, "usb_copy_running", lambda: True)
    code, _, err = server.start_usb_copy([{"root": "mirror", "path": "raw"}], "")
    assert code != 0
    assert "already running" in err


def test_copy_builds_an_rsync_command_into_the_usb_root(roots, monkeypatch):
    _, mirror, usb = roots
    monkeypatch.setattr(server, "usb_copy_running", lambda: False)
    seen = {}

    def fake_run_cmd(args, input_text=None, timeout=120):
        seen["args"] = args
        return 0, "", ""

    monkeypatch.setattr(server, "run_cmd", fake_run_cmd)
    code, _, _ = server.start_usb_copy([{"root": "mirror", "path": "raw"}], "")

    assert code == 0
    args = seen["args"]
    # Must not block the request thread: a copy runs for minutes to hours.
    assert "--no-block" in args
    assert str((mirror / "raw").resolve()) in args
    assert args[-1] == f"{usb.resolve()}/"


def test_progress_reads_the_latest_update_from_a_collapsed_line():
    # rsync redraws its status line with carriage returns and nothing converts
    # them to newlines, so the journal hands back every update glued together.
    # Reading it whole would render the entire history at once.
    collapsed = (
        "Starting citostore-usb-copy.service...\n"
        "\r         32,768   0%    0.00kB/s    0:00:00  "
        "\r      2,097,152   0%    5.41MB/s    0:00:00 (xfr#1, to-chk=122/124)"
        "\r    268,435,456  63%   21.34MB/s    0:00:07  "
    )
    p = server.parse_rsync_progress(collapsed)
    assert p == {
        "bytes": "268,435,456",
        "percent": 63,
        "rate": "21.34MB/s",
        "eta": "0:00:07",
    }


def test_progress_is_empty_before_rsync_says_anything():
    assert server.parse_rsync_progress("Starting...\nFinished.") == {}
    assert server.parse_rsync_progress("") == {}


def test_copy_scans_up_front_so_the_percentage_means_something(roots, monkeypatch):
    monkeypatch.setattr(server, "usb_copy_running", lambda: False)
    seen = {}
    monkeypatch.setattr(
        server, "run_cmd", lambda args, **kw: (seen.update(args=args), (0, "", ""))[1]
    )
    server.start_usb_copy([{"root": "mirror", "path": "raw"}], "")
    # Without this rsync does not know the total yet and the ETA chases a moving
    # target for the first part of a big copy.
    assert "--no-inc-recursive" in seen["args"]


def test_progress_goes_to_a_file_not_the_journal(roots, monkeypatch):
    monkeypatch.setattr(server, "usb_copy_running", lambda: False)
    seen = {}
    monkeypatch.setattr(
        server, "run_cmd", lambda args, **kw: (seen.update(args=args), (0, "", ""))[1]
    )
    server.start_usb_copy([{"root": "mirror", "path": "raw"}], "")
    args = seen["args"]
    # journald splits on newlines and rsync writes only carriage returns, so the
    # journal stayed empty until rsync exited — and 49k files of output would
    # flood a RAM-backed journal capped at 64M.
    assert f"--property=StandardOutput=file:{server.USB_PROGRESS_FILE}" in args
    # ...and rsync buffers when stdout is not a tty, so it must be told not to.
    assert "--outbuf=N" in args


def test_progress_tail_reads_only_the_end(tmp_path, monkeypatch):
    f = tmp_path / "prog"
    f.write_text("x" * 9000 + "\r    268,435,456  63%   21.34MB/s    0:00:07  ", encoding="utf-8")
    monkeypatch.setattr(server, "USB_PROGRESS_FILE", str(f))
    assert server.parse_rsync_progress(server.read_progress_tail())["percent"] == 63
    assert len(server.read_progress_tail()) <= 4096


def test_progress_tail_survives_a_missing_file(monkeypatch, tmp_path):
    monkeypatch.setattr(server, "USB_PROGRESS_FILE", str(tmp_path / "nope"))
    assert server.read_progress_tail() == ""
    assert server.parse_rsync_progress(server.read_progress_tail()) == {}


def test_stale_progress_is_cleared_before_a_new_copy(roots, monkeypatch):
    monkeypatch.setattr(server, "usb_copy_running", lambda: False)
    calls = []
    monkeypatch.setattr(
        server, "run_cmd", lambda args, **kw: (calls.append(args), (0, "", ""))[1]
    )
    monkeypatch.setattr(
        server, "run_privileged", lambda args, **kw: (calls.append(args), (0, "", ""))[1]
    )
    server.start_usb_copy([{"root": "mirror", "path": "raw"}], "")

    # systemd truncates the file only once rsync opens it, and --no-block returns
    # before that: the page would read the previous copy's final line and flash
    # 100% before the new one has moved a byte.
    rm = [c for c in calls if c[0] == "/bin/rm"]
    run = [i for i, c in enumerate(calls) if c[0] == "systemd-run"]
    assert rm and rm[0] == ["/bin/rm", "-f", server.USB_PROGRESS_FILE]
    assert calls.index(rm[0]) < run[0], "must be cleared before the copy starts"


# --- protected folders -----------------------------------------------------

def test_protected_refuses_paths_outside_the_mirror(roots, monkeypatch):
    monkeypatch.setattr(server, "run_privileged", lambda *a, **k: (0, "", ""))
    with pytest.raises(ValueError):
        server.set_protected_paths(["../outside.txt"])


def test_protected_refuses_state(roots, monkeypatch):
    monkeypatch.setattr(server, "run_privileged", lambda *a, **k: (0, "", ""))
    with pytest.raises(ValueError):
        server.set_protected_paths([".state"])


def test_protected_refuses_a_path_that_is_not_a_folder(roots, monkeypatch):
    monkeypatch.setattr(server, "run_privileged", lambda *a, **k: (0, "", ""))
    code, _, err = server.set_protected_paths(["raw/2026/img.png"])
    assert code != 0 and "not a folder" in err


def test_protected_writes_a_list_retention_can_parse(roots, monkeypatch, tmp_path):
    # mirror-retention.sh aborts its whole run on a list it cannot parse, so a
    # malformed write here would stop retention dead.
    written = {}

    def fake_privileged(args, input_text=None, **kw):
        if args[0].endswith("tee"):
            written["payload"] = input_text
        return 0, "", ""

    monkeypatch.setattr(server, "run_privileged", fake_privileged)
    code, _, _ = server.set_protected_paths(["raw/2026", "raw/2026", "/raw//"])
    assert code == 0
    data = json.loads(written["payload"])
    assert data["paths"] == ["raw", "raw/2026"], "deduped, normalised, sorted"

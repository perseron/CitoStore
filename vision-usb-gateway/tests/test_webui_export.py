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

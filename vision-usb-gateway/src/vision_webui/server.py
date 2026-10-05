#!/usr/bin/env python3
import base64
import contextlib
import hashlib
import hmac
import html
import ipaddress
import json
import os
import pwd
import re
import secrets
import socket
import subprocess
import tarfile
import threading
import time
from contextlib import contextmanager
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from vision_sync.config import parse_config_text
from vision_sync.fsops import safe_join

STATE_DIR = Path("/srv/vision_mirror/.state")
SHADOW_CONF = STATE_DIR / "vision-gw.conf"
PASS_FILE = STATE_DIR / "webui.passwd"
SECRET_FILE = STATE_DIR / "webui.secret"
LOG_FILE = STATE_DIR / "vision-webui.log"
LOCK_FILE = Path("/run/vision-webui.lock")

STATIC_DIR = Path(__file__).resolve().parent / "static"

DEFAULT_CONF = Path("/etc/vision-gw.conf")
NAS_CREDS = Path("/etc/vision-nas.creds")
NAS_CREDS_SHADOW = STATE_DIR / "vision-nas.creds"
NETWORK_STATE = STATE_DIR / "network.json"

SESSION_TTL_SEC = 8 * 60 * 60
MAX_BODY_SIZE = 64 * 1024
MAX_UPDATE_SIZE = 50 * 1024 * 1024  # 50MB for update packages
MAX_BUNDLE_SIZE = 64 * 1024 * 1024  # config bundle (.citostore): config + secrets + passdb
MAINT_MODE_FLAG = Path("/run/vision-maintenance-mode")

# Config bundle provisioning: staged on tmpfs so it survives the NVMe wipe.
PROVISION_STAGE = Path("/run/vision-provision")
BUNDLE_STAGED = PROVISION_STAGE / "bundle.citostore"

ALLOWED_CONFIG_KEYS = {
    "NETBIOS_NAME",
    "SMB_WORKGROUP",
    "SMB_BIND_INTERFACE",
    "SYNC_INTERVAL_SEC",
    "SYNC_ONBOOT_SEC",
    "SYNC_ONACTIVE_SEC",
    "SYNC_HI_INTERVAL_SEC",
    "SYNC_SCAN_DEPTH",
    "SYNC_HOT_DIRS",
    "SYNC_COLD_AUDIT_DIRS_PER_RUN",
    "NAS_ENABLED",
    "NAS_REMOTE",
    "NAS_MOUNT",
    "WEBUI_BIND",
    "WEBUI_PORT",
    "USB_LV_SIZE",
    "BYDATE_USE_FILE_TIME",
    "RAW_APPEND_ALWAYS",
    "SWITCH_WINDOW_START",
    "SWITCH_WINDOW_END",
    "SWITCH_DELAY_SEC",
    "ETH1_ENABLED",
    "ETH1_ADDRESS",
    "ETH1_PREFIX",
    "ETH1_GATEWAY",
    "INGEST_ENABLED",
    "FTP_ENABLED",
    "SFTP_ENABLED",
    "FTP_USER",
    "MIRROR_FTP_ENABLED",
    "MIRROR_FTP_BIND_INTERFACE",
}

SERVICES = [
    "usb-gadget.service",
    "vision-sync.service",
    "vision-monitor.service",
    "vision-rotator.service",
    "vision-gw-config.service",
    "smbd.service",
    "nmbd.service",
    "wsdd.service",
    "vision-webui.service",
]

LOG_SERVICES = sorted(
    set(
        SERVICES
        + [
            "vision-wipe.service",
            "vision-usb-format.service",
            "vision-nvme-health.service",
            "vision-gw-health.service",
            "vision-sync.timer",
            "vision-monitor.timer",
            "vision-rotator.timer",
            "vision-log-cleanup.service",
            "vision-log-cleanup.timer",
        ]
    )
)


MIRROR_MOUNT = Path("/srv/vision_mirror")
STORAGE_MISSING = (
    "The unit's NVMe storage is not mounted: settings cannot be saved "
    "(they would be lost at the next restart). See the health banner or contact service."
)
# POSTs that persist into STATE_DIR. With the NVMe not mounted (fstab nofail),
# /srv/vision_mirror is a bare tmpfs directory: they "succeeded" and vanished at
# the next boot. Maintenance actions are not here on purpose (Factory Reset and
# Safe Shutdown must keep working on a unit with a broken disk).
STATE_WRITING_POSTS = {
    "/api/config", "/api/nas-creds", "/api/apply", "/api/password/webui",
    "/api/password/smb", "/api/password/ftp", "/api/network", "/api/config/import",
    "/api/update",
}


def mirror_mounted() -> bool:
    return os.path.ismount(MIRROR_MOUNT)


def get_gateway_home() -> str:
    # The install location comes from the unit's environment (GATEWAY_HOME,
    # /etc/vision-gw.env), not the shadow config: an imported config carrying
    # an old path broke every script call from the WebUI until the next boot.
    env = os.environ.get("GATEWAY_HOME")
    if env:
        return env
    cfg = parse_config(load_config_text())
    return cfg.get("GATEWAY_HOME", "/opt/CitoStore/vision-usb-gateway")


def log(msg: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(f"[{timestamp}] {msg}\n")


def run_cmd(args, input_text=None, timeout=120, env=None):
    try:
        result = subprocess.run(
            args,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            env=env,
        )
    except subprocess.TimeoutExpired:
        # Uncaught, it dropped the connection: the page got no answer at all
        # instead of an error saying the operation did not finish.
        return 124, "", f"{args[0]}: no answer within {timeout} s"
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def run_privileged(args, input_text=None, timeout=120):
    """Run a system-mutating command outside this service's sandbox.

    vision-webui.service runs under ProtectSystem=strict with a narrow
    ReadWritePaths list, and any child it spawns inherits that read-only view
    of /etc, /usr, /var, etc. The config-apply and account scripts must write
    broadly under those trees (sed -i tempfiles in /etc, useradd touching
    /etc/passwd + /etc/shadow, network and vsftpd/ssh config, the Samba
    passdb), so running them directly fails with EROFS. Hand them to PID 1 via
    systemd-run instead: the transient unit runs with full root access,
    unconstrained by our sandbox. Running in a separate unit (not our cgroup)
    also means apply-shadow-config restarting vision-webui no longer kills the
    apply mid-run.
    """
    cmd = [
        "systemd-run",
        "--quiet",
        "--collect",
        "--wait",
        "--pipe",
        "--service-type=oneshot",
        "--",
        *args,
    ]
    return run_cmd(cmd, input_text=input_text, timeout=timeout)


# Bounds the retry of a set-time that raced timedatectl's own set-ntp job.
TIME_SET_ATTEMPTS = 8
TIME_SET_RETRY_SEC = 0.3


def set_system_time(value):
    """Set the system clock, taking it back from timesyncd first.

    timedatectl refuses set-time outright while timesyncd owns the clock
    ("Automatic time synchronization is enabled"), so setting the time by hand
    means disabling NTP. An offline unit — the case this exists for — can never
    reach an NTP server anyway; a networked one can be put back on NTP with
    `timedatectl set-ntp true`.

    set-ntp then hands the timesyncd stop to a systemd job and returns before it
    lands, and timedated rejects a set-time overlapping that job with "Previous
    request is not finished, refusing". That reject is timing-dependent (it
    reproduces intermittently), so retry across the window instead of sleeping a
    guessed interval. Any other failure is real and is returned as-is.
    """
    # Checked first: a value timedatectl then refused still left NTP off.
    try:
        time.strptime(value, "%Y-%m-%d %H:%M:%S" if value.count(":") == 2 else "%Y-%m-%d %H:%M")
    except ValueError:
        return 1, "", "the time must look like 2026-07-17 08:30 (or 08:30:00)"
    run_cmd(["/usr/bin/timedatectl", "set-ntp", "false"])
    code, out, err = 1, "", ""
    for attempt in range(TIME_SET_ATTEMPTS):
        code, out, err = run_cmd(["/usr/bin/timedatectl", "set-time", value])
        if code == 0 or "not finished" not in f"{out}{err}":
            break
        if attempt < TIME_SET_ATTEMPTS - 1:
            time.sleep(TIME_SET_RETRY_SEC)
    return code, out, err


BUILD_STAMP = Path("/etc/citostore-build")

# The file manager's two roots. "mirror" is exposed read-only — an operator may
# copy production data off, never delete it — and .state is excluded outright:
# it holds the FTP/NAS/WebUI secrets and the Samba passdb, which an earlier audit
# found leaking over the SMB share. "usb" is whatever is plugged in, or an empty
# mount point when nothing is.
EXPORT_ROOTS = {
    "mirror": Path("/srv/vision_mirror"),
    "usb": Path("/srv/usb_backup"),
}
EXPORT_HIDDEN = {".state"}
USB_JOB_UNIT = "citostore-usb-copy"
# /run is tmpfs: the progress file dies with the boot, which is right — a copy
# does not survive one either.
USB_PROGRESS_FILE = "/run/citostore-usb-copy.progress"
USB_RC_FILE = "/run/citostore-usb-copy.rc"
EXPORT_SESSION_USER = "export"
# Folders retention must never delete. On the NVMe, so it survives an OS reflash
# — protection lapsing after an update would be worse than never offering it.
PROTECTED_FILE = Path("/srv/vision_mirror/.state/retention-protected.json")
RETENTION_BLOCKED = Path("/srv/vision_mirror/.state/retention-blocked.json")


def export_root(name: str) -> Path:
    root = EXPORT_ROOTS.get(name)
    if root is None:
        raise ValueError("unknown root")
    return root


def resolve_export_path(root_name: str, rel: str) -> Path:
    """Resolve a browse/copy path, refusing anything outside its root.

    safe_join resolves symlinks before comparing, so a link planted inside the
    tree cannot walk out of it.
    """
    root = export_root(root_name)
    rel = (rel or "").strip()
    # Deliberately strict: an absolute path is refused rather than quietly
    # reinterpreted under the root, so a caller can never think it addressed
    # /etc/shadow and be handed mirror/etc/shadow instead.
    target = safe_join(root, Path(rel)) if rel else root.resolve()
    parts = target.relative_to(root.resolve()).parts if target != root.resolve() else ()
    if parts and parts[0] in EXPORT_HIDDEN:
        raise ValueError("path not allowed")
    return target


def get_build_stamp() -> dict:
    """Which image this unit was flashed from.

    Written into the image at bake time. Without it there is no way to tell what
    a unit is actually running: the repo's HEAD is only visible over SSH, and it
    lies whenever someone has checked something out into the RAM overlay — which
    reverts on the next boot, so the unit silently goes back to the baked code.
    """
    stamp = {"sha": "unknown", "date": "unknown", "subject": ""}
    try:
        for line in BUILD_STAMP.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key == "CITOSTORE_BUILD_SHA":
                stamp["sha"] = value
            elif key == "CITOSTORE_BUILD_DATE":
                stamp["date"] = value
            elif key == "CITOSTORE_BUILD_SUBJECT":
                stamp["subject"] = value
    except OSError:
        pass
    return stamp


def read_protected_list() -> tuple[list, str]:
    """(paths, error). An unreadable list used to read as "nothing protected":
    the page showed no folders while mirror-retention.sh (rightly) refused to
    run on it — and saving a new pick then silently replaced what was there."""
    if not PROTECTED_FILE.exists():
        return [], ""
    try:
        data = json.loads(PROTECTED_FILE.read_text(encoding="utf-8"))
        return [str(p) for p in data.get("paths", [])], ""
    except (OSError, ValueError, AttributeError) as exc:
        return [], (
            f"The protected-folder list cannot be read ({exc.__class__.__name__}). "
            "Retention is stopped until the list is saved again — pick the folders and Save."
        )


def get_protected_paths() -> list:
    return read_protected_list()[0]


def set_protected_paths(paths: list) -> tuple:
    """Replace the protected list, after checking every entry is real and inside.

    mirror-retention.sh aborts its whole run on a list it cannot parse — the
    right call, since a broken file must not quietly unprotect anything — which
    makes writing a bad one here a way to stop retention dead. Validate first,
    write atomically second.
    """
    clean = []
    for raw in paths:
        rel = str(raw).strip().strip("/")
        if not rel:
            return 1, "", "empty path"
        target = resolve_export_path("mirror", rel)  # raises on traversal
        if not target.is_dir():
            return 1, "", f"not a folder: {rel}"
        clean.append(rel)
    payload = json.dumps({"paths": sorted(set(clean))}, indent=2)
    # tmp + fsync + rename (atomic_write): the old tee + mv had no fsync, and
    # a list cut short by a power cut stops retention until someone saves.
    try:
        atomic_write(PROTECTED_FILE, payload)
    except OSError as exc:
        return 1, "", str(exc)
    return 0, "", ""


# The protected page polls every 15 s, and `du` walks every protected tree:
# a protected year of images held this single-threaded server for seconds on
# each poll. One du over all of them (hard links — bydate — counted once),
# reused for a few minutes; a changed list is measured at once.
PROTECTED_DU_TTL = 300
_protected_du = {"key": None, "ts": 0.0, "total": 0}


def protected_bytes(paths: list) -> int:
    key = tuple(paths)
    if _protected_du["key"] == key and time.time() - _protected_du["ts"] < PROTECTED_DU_TTL:
        return _protected_du["total"]
    targets = []
    for rel in paths:
        with contextlib.suppress(ValueError, OSError):
            targets.append(str(resolve_export_path("mirror", rel)))
    total = 0
    if targets:
        _, out, _ = run_cmd(["/usr/bin/du", "-sbc", "--", *targets])
        lines = out.strip().splitlines()
        if lines and lines[-1].endswith("total"):
            with contextlib.suppress(ValueError):
                total = int(lines[-1].split()[0])
    _protected_du.update(key=key, ts=time.time(), total=total)
    return total


def get_protected_status() -> dict:
    paths, list_error = read_protected_list()
    total = protected_bytes(paths)
    usage = get_disk_usage(str(EXPORT_ROOTS["mirror"]))
    blocked = None
    with contextlib.suppress(OSError, ValueError):
        blocked = json.loads(RETENTION_BLOCKED.read_text(encoding="utf-8"))
    return {
        "paths": paths,
        "protected_bytes": total,
        "mirror": usage,
        # Set by mirror-retention.sh when protection is why it cannot free space.
        # The mirror then fills, the sync's guard trips, and capture stops — so
        # this must be visible here, not only in a log nobody reads.
        "blocked": blocked,
        "list_error": list_error,
    }


def get_usb_export_status() -> dict:
    """What is plugged into the export port, if anything."""
    mount = str(EXPORT_ROOTS["usb"])
    code, out, _ = run_cmd(["/usr/bin/findmnt", "-no", "SOURCE,FSTYPE,OPTIONS", mount])
    if code != 0 or not out:
        return {"present": False, "mount": mount}
    source, fstype, options = (out.split(None, 2) + ["", ""])[:3]
    info = {
        "present": True,
        "mount": mount,
        "device": source,
        "fstype": fstype,
        "write_through": "sync" in options.split(","),
        "usage": get_disk_usage(mount),
    }
    code, out, _ = run_cmd(["/sbin/blkid", "-o", "value", "-s", "LABEL", source])
    info["label"] = out.strip() if code == 0 else ""
    return info


def list_export_dir(root_name: str, rel: str) -> dict:
    target = resolve_export_path(root_name, rel)
    if not target.is_dir():
        raise ValueError("not a directory")
    root = export_root(root_name).resolve()
    entries = []
    with os.scandir(target) as it:
        for e in it:
            if target == root and e.name in EXPORT_HIDDEN:
                continue
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            entries.append(
                {
                    "name": e.name,
                    "dir": e.is_dir(follow_symlinks=False),
                    "size": st.st_size,
                    "mtime": int(st.st_mtime),
                }
            )
    entries.sort(key=lambda x: (not x["dir"], x["name"].lower()))
    return {
        "root": root_name,
        "path": target.relative_to(root).as_posix() if target != root else "",
        "writable": root_name != "mirror",
        "entries": entries,
    }


def usb_copy_running() -> bool:
    code, out, _ = run_cmd(["/bin/systemctl", "is-active", f"{USB_JOB_UNIT}.service"])
    return out.strip() in ("active", "activating")


def usb_drive_mounted() -> bool:
    """A drive is mounted on the export mount point. The directory itself
    stays behind on the RAM root after a drive was pulled: a copy started then
    (as root, outside the sandbox) wrote into RAM until the unit ran out."""
    return os.path.ismount(EXPORT_ROOTS["usb"])


def start_usb_copy(sources: list, dest_rel: str) -> tuple:
    """Copy into the USB drive in the background, as a transient unit.

    rsync runs under PID 1 rather than in this request: a copy takes minutes to
    hours, and vision-webui is sandboxed (ProtectSystem=strict) so a child of it
    could not write the mount anyway. --no-block returns immediately; progress is
    read back from the unit's journal.
    """
    if usb_copy_running():
        return 1, "", "a copy is already running"
    if not usb_drive_mounted():
        return 1, "", "no USB drive is plugged in"
    dest = resolve_export_path("usb", dest_rel)
    if not dest.is_dir():
        return 1, "", "destination is not a directory on the USB drive"

    srcs = []
    for item in sources:
        # Never the mirror's root: that copied .state too (the session key, the
        # password hashes, the Samba passdb, every credential) onto the stick —
        # the .state check only looks below the root. The page offers folders.
        path = resolve_export_path(item.get("root", "mirror"), item.get("path", ""))
        if item.get("root", "mirror") == "mirror" and path == export_root("mirror").resolve():
            return 1, "", "pick folders inside the mirror, not the mirror itself"
        if not path.exists():
            return 1, "", f"source not found: {item.get('path')}"
        # A trailing slash would copy a directory's *contents*; keep the folder.
        srcs.append(str(path))
    if not srcs:
        return 1, "", "nothing selected"

    # systemd truncates the progress file when rsync opens it, but --no-block
    # returns before that happens: the page polls in between and reads the *last*
    # copy's final line, flashing 100% before the new one has moved a byte.
    run_privileged(["/bin/rm", "-f", USB_PROGRESS_FILE, USB_RC_FILE])

    args = [
        "systemd-run",
        "--quiet",
        "--collect",
        "--no-block",
        f"--unit={USB_JOB_UNIT}",
        "--service-type=oneshot",
        "--property=IOSchedulingClass=best-effort",
        "--property=IOSchedulingPriority=7",
        "--property=Nice=5",
        # Progress goes to a file, never the journal. Two reasons, one fix:
        # journald splits on newlines and rsync only ever writes carriage
        # returns, so the journal held nothing until rsync exited and the bar sat
        # at 0% for the whole copy; and 49k files' worth of output would flood a
        # RAM-backed journal capped at 64M, evicting the logs that matter.
        # stderr still goes to the journal — real errors belong there.
        f"--property=StandardOutput=file:{USB_PROGRESS_FILE}",
        "--",
        # rsync's exit code goes to a file: the unit is --collect'ed, and once a
        # failed transient unit is unloaded `systemctl show -p Result` answers
        # the default "success" — a copy that failed (drive full, pulled) was
        # reported as finished and the operator walked off with an incomplete drive.
        "/bin/sh",
        "-c",
        f'/usr/bin/rsync "$@"; echo $? > {USB_RC_FILE}',
        "citostore-usb-copy",
        "-rlt",
        "--info=progress2",
        # Flush every update: rsync buffers when stdout is not a tty, which would
        # leave the bar stale no matter where the output lands.
        "--outbuf=N",
        # Scan everything up front. rsync's default incremental recursion means
        # it does not know the total yet, so the percentage and ETA crawl toward
        # a moving target and lie for the first part of a big copy. A slower
        # start buys a progress bar that means something.
        "--no-inc-recursive",
        "--no-perms",
        "--no-owner",
        "--no-group",
        *srcs,
        f"{dest}/",
    ]
    return run_cmd(args)


# "  1,234,567,890  45%   12.34MB/s    0:01:23"
PROGRESS_RE = re.compile(
    r"([\d,]+)\s+(\d+)%\s+([\d.]+[kKMG]?B/s)\s+(\d+:\d{2}:\d{2})"
)


def parse_rsync_progress(text: str) -> dict:
    """Pull the latest progress out of rsync's --info=progress2 stream.

    rsync redraws one status line with carriage returns. Nothing converts those
    to newlines, so the journal accumulates every update into a single enormous
    line — reading that line whole would render the entire history at once. Split
    on \\r and take the last update that parsed.
    """
    for chunk in reversed(text.split("\r")):
        m = PROGRESS_RE.search(chunk)
        if m:
            return {
                "bytes": m.group(1),
                "percent": int(m.group(2)),
                "rate": m.group(3),
                "eta": m.group(4),
            }
    return {}


def read_progress_tail(limit: int = 4096) -> str:
    """The end of rsync's progress file.

    It only ever grows — rsync separates updates with carriage returns, so every
    update is appended rather than overwriting. Only the last one matters, and
    reading the whole file would mean re-reading megabytes every second on a long
    copy.
    """
    try:
        with open(USB_PROGRESS_FILE, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - limit))
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def get_usb_copy_status() -> dict:
    active = usb_copy_running()
    result = {"running": active, "progress": parse_rsync_progress(read_progress_tail())}
    if not active:
        result["result"] = usb_copy_result()
    return result


def usb_copy_result() -> str:
    """"success", "failed (rsync exit N)", or "unknown" (no copy ran / killed)."""
    try:
        rc = Path(USB_RC_FILE).read_text(encoding="utf-8").strip()
    except OSError:
        return "unknown"
    if rc == "0":
        return "success"
    return f"failed (rsync exit {rc or '?'})"


def eject_usb() -> tuple:
    """Flush and unmount, so the drive can be pulled with no data left in flight."""
    mount = str(EXPORT_ROOTS["usb"])
    code, out, err = run_cmd(["/bin/findmnt", "-no", "SOURCE", mount])
    if code != 0:
        return 1, "", "nothing is mounted"
    if usb_copy_running():
        return 1, "", "a copy is still running"
    run_privileged(["/bin/sync"])
    return run_privileged(["/bin/umount", mount])


def load_config_text() -> str:
    if SHADOW_CONF.exists():
        return SHADOW_CONF.read_text(encoding="utf-8")
    if DEFAULT_CONF.exists():
        return DEFAULT_CONF.read_text(encoding="utf-8")
    return ""


def parse_config(text: str) -> dict:
    return parse_config_text(text)


# What an imported config line may look like. The shadow config is bash-SOURCED
# by every script (load_config), so anything else is code execution as root or —
# just as bad — a syntax error that stops vision-gw-config at boot and with it
# the WebUI and the sync (both Require it).
_IMPORT_KEY = r"[A-Z_][A-Z0-9_]*"
_IMPORT_VALUE = re.compile(
    r"""(
        [A-Za-z0-9_./:,@%+=-]*                       # bare
      | "[^"$`\\]*"                                   # double-quoted, nothing expanded
      | '[^']*'                                       # single-quoted (literal in bash)
      | \(\s*(?:[A-Za-z0-9_./:@%+-]+\s*)*\)           # array of bare words
    )\s*(?:\#.*)?""",
    re.VERBOSE,
)


def validate_import_config(text: str) -> tuple[str, str]:
    """Return (normalized text, "") or ("", error) for an uploaded config file.

    CRs are dropped (a Windows-saved file is otherwise a stray command per line).
    """
    lines = text.replace("\r", "").split("\n")
    keys = 0
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.fullmatch(rf"({_IMPORT_KEY})=(.*)", s)
        if not m or not _IMPORT_VALUE.fullmatch(m.group(2)):
            return "", f"line {n} is not a plain KEY=value setting: {s[:60]}"
        keys += 1
    if not keys:
        return "", "no valid config entries found"
    return "\n".join(lines).rstrip("\n") + "\n", ""


def bundle_config_error(bundle: Path) -> str:
    """Why a .citostore bundle's vision-gw.conf may not be used ("" if fine).

    The plan step sources it as root, and once provisioned it is the shadow
    config every script sources — so the same plain KEY=value rule as a config
    import: a crafted bundle must not run code on the unit."""
    try:
        with tarfile.open(bundle, "r:gz") as tar:
            member = None
            for name in ("./etc/vision-gw.conf", "etc/vision-gw.conf"):
                try:
                    member = tar.getmember(name)
                    break
                except KeyError:
                    continue
            if member is None or not member.isfile():
                return "bundle missing vision-gw.conf"
            fh = tar.extractfile(member)
            text = fh.read(1024 * 1024).decode("utf-8", errors="replace") if fh else ""
    except (tarfile.TarError, OSError, EOFError):
        return "invalid bundle (not a .citostore archive)"
    _, err = validate_import_config(text)
    return f"bundle config rejected: {err}" if err else ""


HEALTH_FILES = (STATE_DIR / "health.json", Path("/run/vision-health.json"))
BOOT_HEALTH_FILE = Path("/run/vision-health-boot.json")
_HEALTH_RANK = {"ok": 0, "warn": 1, "unknown": 2, "error": 3}


def read_health() -> dict:
    """The live health (vision-monitor, rewritten after every sync) plus what
    this boot's health-check found. The monitor's rewrite used to erase the
    boot findings — a FAT repaired, a USB drive's aoi_settings restored, the
    overlay off — within ~30 s, so the banner never showed them."""
    health = {"status": "unknown", "issues": [], "ts": ""}
    for path in HEALTH_FILES:
        if path.exists():
            try:
                health = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                log(f"{path.name} parse error")
                health = {"status": "unknown", "issues": [f"invalid {path.name}"], "ts": ""}
            break
    try:
        boot = json.loads(BOOT_HEALTH_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return health
    boot_issues = [f"boot: {i}" for i in boot.get("issues", []) if i]
    if boot_issues:
        health = dict(health)
        health["issues"] = list(health.get("issues", [])) + boot_issues
        live, at_boot = health.get("status", "unknown"), boot.get("status", "warn")
        if _HEALTH_RANK.get(at_boot, 1) > _HEALTH_RANK.get(live, 2):
            health["status"] = at_boot
    return health


def atomic_write(path: Path, data, mode: int = 0o644) -> None:
    """tmp + fsync + rename. These units lose power without warning, and an
    in-place write cut short leaves a truncated file on the NVMe: half a config
    (missing keys silently fall back to defaults), an empty session key, broken
    JSON. The tmp is created with its final mode, so a secret is never briefly
    readable by others."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "wb") as fh:
        os.fchmod(fh.fileno(), mode)
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def record_update_history(version: str, status: str) -> None:
    """Append to the history apply-update.sh keeps, for rejections that never
    reach it — otherwise a refused upload leaves no trace the operator can see."""
    path = STATE_DIR / "update-history.json"
    try:
        history = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
    except (OSError, json.JSONDecodeError):
        history = []
    history.append({"version": version, "status": status, "ts": time.strftime("%Y-%m-%dT%H:%M:%S")})
    try:
        atomic_write(path, json.dumps(history[-20:]))
    except OSError as exc:
        log(f"update history write failed: {exc}")


def parse_nas_creds(text: str) -> dict:
    creds = {"username": "", "password": "", "domain": ""}
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        key, value = s.split("=", 1)
        key = key.strip().lower()
        value = value.strip()
        if key == "username":
            creds["username"] = value
        elif key == "password":
            creds["password"] = value
        elif key == "domain":
            creds["domain"] = value
    return creds


def render_nas_creds(creds: dict) -> str:
    lines = [
        f"username={creds.get('username', '').strip()}",
        f"password={creds.get('password', '').strip()}",
    ]
    domain = creds.get("domain", "").strip()
    if domain:
        lines.append(f"domain={domain}")
    return "\n".join(lines) + "\n"


# /etc/vision-gw.conf is `source`d by root shell scripts (scripts/common.sh),
# so any value we write there is shell code. No WebUI-writable key legitimately
# needs a character outside this set.
SAFE_VALUE_CHARS = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" "._:/@+-"
)
MAX_VALUE_LEN = 255


def is_safe_value(value: str) -> bool:
    return len(value) <= MAX_VALUE_LEN and all(c in SAFE_VALUE_CHARS for c in value)


def format_value(value: str) -> str:
    if value == "":
        return '""'
    if not is_safe_value(value):
        # Defense in depth: validate_config_updates must have rejected this.
        raise ValueError("unsafe config value")
    return value


# Passwords are fed to chpasswd/smbpasswd on stdin as line-oriented records, so
# a control character -- a newline above all -- lets a second record be smuggled
# in: an FTP password of "x\nroot:pw" makes chpasswd also reset root's password.
# Reject anything non-printable (str.isprintable() is False for control and
# separator chars, but True for a plain space) and cap the length.
MAX_PASSWORD_LEN = 128


def is_valid_password(password: str) -> bool:
    return 0 < len(password) <= MAX_PASSWORD_LEN and password.isprintable()


def update_config_file(base_text: str, updates: dict) -> str:
    lines = base_text.splitlines()
    seen = set()
    for i, line in enumerate(lines):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        key, _ = s.split("=", 1)
        key = key.strip()
        if key in updates:
            lines[i] = f"{key}={format_value(updates[key])}"
            seen.add(key)
    for key, value in updates.items():
        if key not in seen:
            lines.append(f"{key}={format_value(value)}")
    return "\n".join(lines) + "\n"


# Requests run in threads: two first requests must not both create a key (each
# signing with its own, one of them overwritten).
_SECRET_LOCK = threading.Lock()


def ensure_secret() -> bytes:
    with _SECRET_LOCK:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        if SECRET_FILE.exists():
            secret = SECRET_FILE.read_bytes()
            # A short key (an empty file left by a power cut) would sign sessions
            # with a guessable HMAC key: anyone could forge an admin cookie.
            if len(secret) >= 32:
                return secret
            log("session secret too short; regenerating (all sessions end)")
        secret = secrets.token_bytes(32)
        atomic_write(SECRET_FILE, secret, 0o600)
        return secret


def rotate_secret() -> None:
    """A new session key: every session signed with the old one ends."""
    with _SECRET_LOCK:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        atomic_write(SECRET_FILE, secrets.token_bytes(32), 0o600)


def hash_password(password: str, salt: bytes) -> str:
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 200_000)
    return base64.b64encode(dk).decode("ascii")


def store_password(password: str) -> None:
    salt = secrets.token_bytes(16)
    data = {
        "salt": base64.b64encode(salt).decode("ascii"),
        "hash": hash_password(password, salt),
    }
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    # Atomic: a power cut mid-write left truncated JSON — login then raised and
    # /setup stayed closed (the file exists), so only SSH could recover it.
    atomic_write(PASS_FILE, json.dumps(data), 0o600)


def verify_password(password: str) -> bool:
    if not PASS_FILE.exists():
        return False
    data = json.loads(PASS_FILE.read_text(encoding="utf-8"))
    salt = base64.b64decode(data["salt"])
    expected = data["hash"]
    candidate = hash_password(password, salt)
    return hmac.compare_digest(candidate, expected)


def make_session(user: str) -> str:
    secret = ensure_secret()
    expiry = int(time.time()) + SESSION_TTL_SEC
    nonce = secrets.token_hex(8)
    payload = f"{user}|{expiry}|{nonce}"
    sig = hmac.new(secret, payload.encode("utf-8"), hashlib.sha256).hexdigest()
    token = base64.urlsafe_b64encode(f"{payload}|{sig}".encode()).decode("ascii")
    return token


def validate_session(token: str) -> bool:
    try:
        raw = base64.urlsafe_b64decode(token.encode("ascii")).decode("utf-8")
        user, expiry, nonce, sig = raw.split("|", 3)
        secret = ensure_secret()
        payload = f"{user}|{expiry}|{nonce}"
        expected = hmac.new(secret, payload.encode("utf-8"), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            return False
        return int(expiry) >= int(time.time())
    except Exception:
        return False


def verify_smb_password(password: str) -> bool:
    """Check a password against Samba's own passdb, by asking Samba.

    The export page is guarded by the SMB credential the operator already has for
    \\\\unit\\vision_mirror, so no admin password has to be handed out and the same
    data is not protected by two different strengths. Verified by letting smbd
    authenticate a real session: Samba's NT hash is MD4-based, OpenSSL 3 no longer
    exposes MD4 to hashlib, and hand-rolling MD4 to check a password would be a far
    worse idea than spending the ~44ms this takes.
    """
    if not password or not password.isprintable() or len(password) > MAX_PASSWORD_LEN:
        return False
    cfg = parse_config(load_config_text())
    user = cfg.get("SMB_USER", "smbuser")
    if "%" in user:
        return False
    # The password in PASSWD, not in -U user%password: argv is world-readable
    # in /proc while smbclient runs.
    code, _, _ = run_cmd(
        ["/usr/bin/smbclient", "-L", "localhost", "-U", user],
        timeout=20,
        env={**os.environ, "PASSWD": password},
    )
    return code == 0


def session_user(token: str) -> str:
    """The user a session was issued to, or "" if it is not valid."""
    if not token or not validate_session(token):
        return ""
    try:
        raw = base64.urlsafe_b64decode(token.encode("ascii")).decode("utf-8")
        return raw.split("|", 1)[0]
    except Exception:
        return ""


def make_csrf(token: str) -> str:
    secret = ensure_secret()
    return hmac.new(secret, token.encode("utf-8"), hashlib.sha256).hexdigest()


def get_cookie(headers, name: str) -> str | None:
    cookie = headers.get("Cookie", "")
    for part in cookie.split(";"):
        if "=" in part:
            k, v = part.strip().split("=", 1)
            if k == name:
                return v
    return None


@contextmanager
def require_lock():
    import fcntl

    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    f = LOCK_FILE.open("w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield f
    finally:
        f.close()


def get_service_status() -> dict:
    status = {}
    for svc in SERVICES:
        code, out, _ = run_cmd(
            ["systemctl", "show", "-p", "ActiveState", "-p", "SubState", svc]
        )
        active = "unknown"
        sub = "unknown"
        if code == 0:
            for line in out.splitlines():
                if line.startswith("ActiveState="):
                    active = line.split("=", 1)[1]
                elif line.startswith("SubState="):
                    sub = line.split("=", 1)[1]
        status[svc] = {"active": active, "sub": sub}
    return status


def get_sync_timer_status() -> dict:
    code, out, err = run_cmd(
        [
            "systemctl",
            "show",
            "-p",
            "NextElapseUSecRealtime",
            "-p",
            "LastTriggerUSecRealtime",
            "-p",
            "NextElapseUSecMonotonic",
            "vision-sync.timer",
        ]
    )
    if code != 0:
        return {"error": err or "failed to read timer"}
    data = {}
    for line in out.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            data[key] = value
    next_trigger = data.get("NextElapseUSecRealtime", "n/a")
    last_trigger = data.get("LastTriggerUSecRealtime", "n/a")
    next_mono_raw = data.get("NextElapseUSecMonotonic", "n/a")
    next_remaining = "n/a"
    try:
        if next_mono_raw not in ("n/a", "infinity", ""):
            total_sec = parse_duration_seconds(next_mono_raw)
            with open("/proc/uptime", encoding="utf-8") as f:
                uptime_sec = float(f.read().split()[0])
            delta = max(0, total_sec - uptime_sec)
            secs = int(delta)
            mins, secs = divmod(secs, 60)
            hours, mins = divmod(mins, 60)
            if hours:
                next_remaining = f"{hours}h {mins}m {secs}s"
            elif mins:
                next_remaining = f"{mins}m {secs}s"
            else:
                next_remaining = f"{secs}s"
    except (ValueError, OSError):
        next_remaining = "n/a"
    return {
        "next_trigger": next_trigger,
        "last_trigger": last_trigger,
        "next_remaining": next_remaining,
    }


def get_sync_service_status() -> dict:
    code, out, err = run_cmd(
        [
            "systemctl",
            "show",
            "-p",
            "CPUUsageNSec",
            "-p",
            "ExecMainStartTimestamp",
            "-p",
            "ExecMainExitTimestamp",
            "-p",
            "ExecMainStartTimestampMonotonic",
            "-p",
            "ExecMainExitTimestampMonotonic",
            "-p",
            "ActiveEnterTimestamp",
            "-p",
            "Result",
            "vision-sync.service",
        ]
    )
    if code != 0:
        return {"error": err or "failed to read sync service status"}
    data = {}
    for line in out.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            data[key] = value

    cpu_nsec_raw = data.get("CPUUsageNSec", "0")
    cpu_total_sec = None
    try:
        cpu_total_sec = round(int(cpu_nsec_raw) / 1_000_000_000, 3)
    except ValueError:
        cpu_total_sec = None

    runtime_sec = None
    start_mono = data.get("ExecMainStartTimestampMonotonic", "0")
    exit_mono = data.get("ExecMainExitTimestampMonotonic", "0")
    try:
        start_us = int(start_mono)
        exit_us = int(exit_mono)
        if exit_us >= start_us and start_us > 0:
            runtime_sec = round((exit_us - start_us) / 1_000_000, 3)
    except ValueError:
        runtime_sec = None

    last_finish = data.get("ExecMainExitTimestamp", "") or data.get("ActiveEnterTimestamp", "n/a")
    if not last_finish:
        last_finish = "n/a"

    return {
        "cpu_total_sec": cpu_total_sec,
        "last_runtime_sec": runtime_sec,
        "last_finish": last_finish,
        "result": data.get("Result", "unknown"),
    }


def parse_duration_seconds(text: str) -> float:
    units = {
        "ms": 0.001,
        "us": 0.000001,
        "µs": 0.000001,
        "ns": 0.000000001,
        "s": 1.0,
        "sec": 1.0,
        "secs": 1.0,
        "second": 1.0,
        "seconds": 1.0,
        "m": 60.0,
        "min": 60.0,
        "mins": 60.0,
        "minute": 60.0,
        "minutes": 60.0,
        "h": 3600.0,
        "hr": 3600.0,
        "hrs": 3600.0,
        "hour": 3600.0,
        "hours": 3600.0,
        "d": 86400.0,
        "day": 86400.0,
        "days": 86400.0,
    }
    total = 0.0
    for token in text.split():
        num = ""
        unit = ""
        for ch in token:
            if ch.isdigit() or ch == ".":
                num += ch
            else:
                unit += ch
        if not num:
            continue
        unit = unit.strip()
        if unit == "":
            # Default to seconds if unit missing.
            total += float(num)
        elif unit in units:
            total += float(num) * units[unit]
        else:
            raise ValueError(f"unknown unit: {unit}")
    return total


def get_active_usb_lv() -> str:
    path = STATE_DIR / "vision-usb-active"
    if path.exists():
        return path.read_text(encoding="utf-8").strip()
    return "unknown"


def get_usb_lv_usage(lv_path: str) -> dict:
    if not lv_path or lv_path == "unknown":
        return {"error": "unknown LV"}
    cache_path = Path("/run/vision-usb-usage.json")
    if cache_path.exists():
        try:
            cached = json.loads(cache_path.read_text(encoding="utf-8"))
            if cached.get("lv") == lv_path:
                return {
                    "size": cached.get("size", ""),
                    "used": cached.get("used", ""),
                    "percent": cached.get("percent", ""),
                    "ts": cached.get("ts", ""),
                }
        except json.JSONDecodeError:
            pass
    code, out, err = run_cmd(
        [
            "lvs", "-a", "--noheadings", "--units", "g",
            "--nosuffix", "-o", "lv_path,lv_size,data_percent",
        ]
    )
    if code != 0:
        return {"error": err or "failed to read LV usage"}
    for line in out.splitlines():
        parts = [p for p in line.strip().split() if p]
        if len(parts) < 2:
            continue
        if parts[0] == lv_path:
            size = parts[1]
            data_percent = parts[2] if len(parts) > 2 else ""
            return {"size_gb": size, "data_percent": data_percent}
    return {"error": "LV not found"}


def get_nm_active_connection(iface: str) -> str | None:
    code, out, _ = run_cmd(["nmcli", "-t", "-f", "NAME,DEVICE", "connection", "show", "--active"])
    if code != 0:
        return None
    for line in out.splitlines():
        name, dev = (line.split(":", 1) + [""])[:2]
        if dev == iface:
            return name
    return None


def get_network_config(iface: str) -> dict:
    conn = get_nm_active_connection(iface)
    if not conn:
        return {"interface": iface, "error": "no active connection for interface"}
    code, out, err = run_cmd(
        [
            "nmcli",
            "-g",
            "ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns",
            "connection",
            "show",
            conn,
        ]
    )
    if code != 0:
        return {"interface": iface, "error": err or "failed to read connection"}
    method, addresses, gateway, dns = (out.split("\n") + ["", "", "", ""])[:4]
    return {
        "interface": iface,
        "connection": conn,
        "method": method,
        "address": addresses,
        "gateway": gateway,
        "dns": dns,
    }


def get_disk_usage(path: str) -> dict:
    code, out, err = run_cmd(
        ["df", "-h", "--output=source,size,used,avail,pcent,target", path]
    )
    if code != 0:
        return {"error": err or "failed to read disk usage"}
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if len(lines) < 2:
        return {"error": "no disk usage data"}
    parts = lines[1].split()
    if len(parts) < 6:
        return {"error": "unexpected disk usage format"}
    return {
        "source": parts[0],
        "size": parts[1],
        "used": parts[2],
        "avail": parts[3],
        "percent": parts[4],
        "target": parts[5],
    }


def get_nvme_smart() -> dict:
    cache_paths = [Path("/run/vision-nvme.json"), STATE_DIR / "nvme.json"]
    for path in cache_paths:
        if path.exists():
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                return {"error": "failed to parse nvme cache"}
            if payload.get("status") != "ok":
                return {"error": payload.get("error", "nvme smart unavailable"), "health": "error"}
            smart = payload.get("smart", {})
            device = payload.get("device", "")
            temp = smart.get("temperature")
            temp_c = None
            if isinstance(temp, (int, float)) and temp >= 200:
                temp_c = round(temp - 273.15, 1)
            elif isinstance(temp, (int, float)):
                temp_c = temp
            # nvme-cli's JSON key is percent_used; percentage_used (its text
            # output's name) was read here, so the wear level never showed.
            used = smart_int(smart.get("percent_used", smart.get("percentage_used")))
            return {
                "device": device,
                "ts": payload.get("ts", ""),
                # Judged by nvme-health.sh (critical warning flags, spare, wear,
                # media errors, the drive's own temperature limits).
                "health": payload.get("health", "unknown"),
                "issues": [msg for _, msg in payload.get("issues", [])],
                "temperature_c": temp_c,
                "percentage_used": used,
                "available_spare": smart_int(smart.get("avail_spare")),
                "spare_threshold": smart_int(smart.get("spare_thresh")),
                "data_units_read": smart.get("data_units_read"),
                "data_units_written": smart.get("data_units_written"),
                "data_units_written_tb": units_to_tb(smart.get("data_units_written")),
                "power_on_hours": smart_int(smart.get("power_on_hours")),
                "unsafe_shutdowns": smart_int(smart.get("unsafe_shutdowns")),
                "media_errors": smart_int(smart.get("media_errors")),
            }
    return {"error": "nvme smart cache not available"}


def smart_int(value) -> int | None:
    """nvme-cli prints big counters as "2,752,848" strings."""
    if isinstance(value, str):
        value = value.replace(",", "").strip()
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def units_to_tb(units) -> float | None:
    try:
        if units is None:
            return None
        if isinstance(units, str):
            units = units.replace(",", "").strip()
        # NVMe data units are 512,000 bytes each (per spec).
        bytes_total = int(units) * 512_000
        return round(bytes_total / 1_000_000_000_000, 2)
    except (ValueError, TypeError):
        return None


# network.json is the persistent truth for the base network (eth0). The WebUI
# only saves it; scripts/apply-network.sh applies it — at boot, when a cable is
# plugged into a static-IP unit, and two seconds after the WebUI answered a
# change. Applied from the request itself, the change took away the address the
# browser was using, so the reply never arrived (as on eth1); and on a direct
# laptop link the active profile is the DHCP server itself, which the request
# rewrote into a DHCP client (no address for the next laptop until a reboot) or
# into the static address.
NETWORK_RESULT = Path("/run/vision-network-apply.json")
NETWORK_APPLY_UNIT = "vision-network-apply"
# "Answer first, apply two seconds later": a transient timer. AccuracySec, as a
# timer's default 1 min of slack let it fire anywhere up to a minute late
# (measured 6 s) while the page follows the unit after 12 s.
DEFERRED_RUN = ["systemd-run", "--quiet", "--collect", "--on-active=2", "--timer-property=AccuracySec=100ms"]


def apply_error(text: str) -> str:
    """What a failed apply tells the operator: its ERROR lines, without the log
    timestamps — not the whole log of every step (the status line showed ~10
    lines with the reason somewhere in the middle)."""
    lines = [re.sub(r"^\[[^\]]*\]\s*", "", line) for line in text.splitlines()]
    errors = [line for line in lines if line.startswith("ERROR")]
    errors = errors or [line for line in lines if "FAILED" in line]
    return "\n".join(errors) or text


def mgmt_iface(cfg: dict) -> str:
    """The management interface the base network setting is for (SMB, WebUI,
    direct laptop link). Never taken from the request: the form's free-text
    interface field let "eth1" rewrite the AOI link's profile."""
    return cfg.get("MDNS_INTERFACE", "eth0") or "eth0"


def eth1_network(cfg: dict):
    """eth1's (AOI link) network when it is enabled, else None."""
    if cfg.get("ETH1_ENABLED", "false") != "true":
        return None
    try:
        prefix = int(cfg.get("ETH1_PREFIX", "24") or "24")
        return ipaddress.IPv4Network(f"{cfg.get('ETH1_ADDRESS', '')}/{prefix}", strict=False)
    except ValueError:
        return None


def host_address_error(ip: ipaddress.IPv4Address, net: ipaddress.IPv4Network) -> str:
    """Why <ip> cannot be an interface's own address in <net> ("" if it can)."""
    if ip.is_loopback or ip.is_multicast or ip.is_unspecified or ip.is_link_local or ip.is_reserved:
        return f"{ip} is not a usable host address"
    if net.prefixlen <= 30 and ip in (net.network_address, net.broadcast_address):
        return f"{ip} is the network or broadcast address of {net}"
    return ""


def validate_network(cfg: dict, data: dict) -> tuple[str, dict]:
    """("", the network.json record) or (error, {}) for a base network change."""
    record = {
        "interface": mgmt_iface(cfg),
        "method": str(data.get("method", "auto")),
        "address": "",
        "prefix": "",
        "gateway": "",
        "dns": "",
    }
    if record["method"] == "auto":
        return "", record
    if record["method"] != "manual":
        return "method must be auto (DHCP) or manual (static)", {}
    try:
        ip = ipaddress.IPv4Address(str(data.get("address", "")).strip())
        prefix = int(str(data.get("prefix", "")).strip())
        if not 1 <= prefix <= 32:
            raise ValueError
        net = ipaddress.IPv4Network(f"{ip}/{prefix}", strict=False)
    except ValueError:
        return "a static address needs an IPv4 address and a prefix of 1-32", {}
    error = host_address_error(ip, net)
    if error:
        return error, {}
    gateway = str(data.get("gateway", "")).strip()
    if gateway:
        try:
            gw = ipaddress.IPv4Address(gateway)
        except ValueError:
            return "the gateway must be an IPv4 address", {}
        if gw not in net or gw == ip:
            return f"gateway {gateway} is not another host in {net}", {}
    servers = [s.strip() for s in str(data.get("dns", "")).split(",") if s.strip()]
    try:
        for server in servers:
            ipaddress.IPv4Address(server)
    except ValueError:
        return "DNS servers must be IPv4 addresses, comma-separated", {}
    aoi = eth1_network(cfg)
    if aoi is not None and net.overlaps(aoi):
        return (
            f"{net} overlaps the AOI link (eth1, {aoi}): eth0 needs a subnet of "
            "its own — or change eth1's address first.",
            {},
        )
    record.update(address=str(ip), prefix=str(prefix), gateway=gateway, dns=",".join(servers))
    return "", record


def read_network_state() -> dict:
    with contextlib.suppress(OSError, ValueError):
        data = json.loads(NETWORK_STATE.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    return {}


def get_network_setting(cfg: dict) -> dict:
    """The saved base network setting (what the form edits) — not the live
    profile, which on a direct laptop link is the DHCP server's ("shared")."""
    iface = mgmt_iface(cfg)
    saved = read_network_state()
    out = {"interface": iface, "method": "auto", "address": "", "gateway": "", "dns": ""}
    if saved.get("method") == "manual" and saved.get("address"):
        out.update(
            method="manual",
            address=f"{saved['address']}/{saved.get('prefix') or 24}",
            gateway=saved.get("gateway") or "",
            dns=saved.get("dns") or "",
        )
    out["live"] = ", ".join(str(i) for i in iface_ipv4(iface))
    with contextlib.suppress(OSError, ValueError):
        out["last_apply"] = json.loads(NETWORK_RESULT.read_text(encoding="utf-8"))
    return out


# USB LV size: what lvcreate -V and the resize script both accept. A whole
# number of MiB/GiB; "0G", "4GB", "1.5G" or K-sized volumes used to reach
# lvcreate only after the old LV had already been removed.
LV_SIZE_RE = re.compile(r"^[1-9][0-9]{0,6}[MG]$")


def validate_config_updates(updates: dict) -> tuple[bool, str]:
    for key, value in updates.items():
        if not is_safe_value(value):
            return False, f"{key} contains unsafe characters"
    if "NAS_REMOTE" in updates:
        remote = updates["NAS_REMOTE"]
        if remote and not remote.startswith("//"):
            return False, "NAS_REMOTE must look like //server/share"
    for key in ("NAS_MOUNT", "NAS_REMOTE"):
        if key in updates and ".." in updates[key]:
            return False, f"{key} must not contain '..'"
    if "NAS_MOUNT" in updates and not updates["NAS_MOUNT"].startswith("/"):
        return False, "NAS_MOUNT must be an absolute path"
    if "USB_LV_SIZE" in updates:
        updates["USB_LV_SIZE"] = size = updates["USB_LV_SIZE"].strip().upper()
        if not LV_SIZE_RE.match(size):
            return False, "USB_LV_SIZE must look like 100G or 512M"
    if "NETBIOS_NAME" in updates:
        name = updates["NETBIOS_NAME"]
        if not name or len(name) > 15 or not name.replace("-", "").replace("_", "").isalnum():
            return False, "NETBIOS_NAME must be 1-15 alphanumeric characters"
    if "SMB_WORKGROUP" in updates:
        wg = updates["SMB_WORKGROUP"]
        if not wg or len(wg) > 15 or not wg.replace("-", "").replace("_", "").isalnum():
            return False, "SMB_WORKGROUP must be 1-15 alphanumeric characters"
    if "SMB_BIND_INTERFACE" in updates:
        iface = updates["SMB_BIND_INTERFACE"]
        if not iface or not all(c.isalnum() or c in "._:-" for c in iface):
            return False, "SMB_BIND_INTERFACE contains invalid characters"
    for key in (
        "SYNC_INTERVAL_SEC", "SYNC_ONBOOT_SEC",
        "SYNC_ONACTIVE_SEC", "SYNC_HI_INTERVAL_SEC",
    ):
        if key in updates:
            val = updates[key]
            if not val or not all(c.isalnum() for c in val):
                return False, f"{key} must be a systemd time string like 30s or 2min"
    for key, min_v, max_v in (
        ("SYNC_SCAN_DEPTH", 1, 16),
        ("SYNC_HOT_DIRS", 1, 32),
        ("SYNC_COLD_AUDIT_DIRS_PER_RUN", 0, 32),
    ):
        if key in updates:
            try:
                val = int(updates[key])
            except ValueError:
                return False, f"{key} must be an integer"
            if val < min_v or val > max_v:
                return False, f"{key} out of range ({min_v}-{max_v})"
    if "WEBUI_PORT" in updates:
        try:
            port = int(updates["WEBUI_PORT"])
            if port < 1 or port > 65535:
                return False, "WEBUI_PORT out of range"
        except ValueError:
            return False, "WEBUI_PORT must be a number"
    if "WEBUI_BIND" in updates:
        bind = updates["WEBUI_BIND"]
        if bind not in ("0.0.0.0", "127.0.0.1") and not all(
            c.isalnum() or c in ".:-" for c in bind
        ):
            return False, "WEBUI_BIND contains invalid characters"
    if "NAS_ENABLED" in updates and updates["NAS_ENABLED"] not in ("true", "false"):
        return False, "NAS_ENABLED must be true or false"
    for key in ("BYDATE_USE_FILE_TIME", "RAW_APPEND_ALWAYS"):
        if key in updates and updates[key] not in ("true", "false"):
            return False, f"{key} must be true or false"
    for key in ("SWITCH_WINDOW_START", "SWITCH_WINDOW_END"):
        if key in updates and not re.match(r"^\d{1,2}:\d{2}$", updates[key]):
            return False, f"{key} must be HH:MM format"
    if "SWITCH_DELAY_SEC" in updates:
        try:
            val = float(updates["SWITCH_DELAY_SEC"])
            if val < 0 or val > 10:
                return False, "SWITCH_DELAY_SEC out of range (0-10)"
        except ValueError:
            return False, "SWITCH_DELAY_SEC must be a number"
    for key in ("ETH1_ENABLED", "INGEST_ENABLED", "FTP_ENABLED", "SFTP_ENABLED"):
        if key in updates and updates[key] not in ("true", "false"):
            return False, f"{key} must be true or false"
    for key in ("ETH1_ADDRESS", "ETH1_GATEWAY"):
        if key in updates and updates[key]:
            try:
                ipaddress.ip_address(updates[key])
            except ValueError:
                return False, f"{key} must be a valid IP address"
    if "ETH1_PREFIX" in updates:
        try:
            p = int(updates["ETH1_PREFIX"])
            if p < 1 or p > 32:
                return False, "ETH1_PREFIX out of range (1-32)"
        except ValueError:
            return False, "ETH1_PREFIX must be a number"
    if "FTP_USER" in updates:
        u = updates["FTP_USER"]
        if not u or not all(c.isalnum() or c in "_-" for c in u):
            return False, "FTP_USER must be alphanumeric"
    return True, ""


def iface_ipv4(iface: str) -> list:
    """IPv4 interfaces (address/prefix) currently on <iface>."""
    code, out, _ = run_cmd(["ip", "-4", "-o", "addr", "show", iface])
    found = []
    if code == 0:
        for line in out.splitlines():
            parts = line.split()
            if "inet" in parts:
                with contextlib.suppress(ValueError, IndexError):
                    found.append(ipaddress.ip_interface(parts[parts.index("inet") + 1]))
    return found


def eth0_networks(cfg: dict) -> list:
    """(network, what) pairs eth1 must stay clear of: what eth0 has now, its
    configured static network, and the direct-link subnet it serves itself."""
    nets = [(i.network, "eth0's current network") for i in iface_ipv4("eth0")]
    with contextlib.suppress(OSError, ValueError, KeyError, TypeError):
        net = json.loads(NETWORK_STATE.read_text(encoding="utf-8"))
        if net.get("method") == "manual" and net.get("address"):
            nets.append((
                ipaddress.ip_interface(f"{net['address']}/{net.get('prefix') or 24}").network,
                "eth0's static network",
            ))
    with contextlib.suppress(ValueError):
        direct = cfg.get("MDNS_DIRECT_SUBNET", "10.10.10") or "10.10.10"
        nets.append((ipaddress.ip_network(f"{direct}.0/24"), "the direct laptop link (eth0)"))
    return nets


def validate_eth1(cfg: dict) -> tuple[bool, str]:
    """Cross-field checks on the merged (saved + submitted) eth1 settings.

    The per-field checks let through what the unit then could not use
    (checked against NetworkManager 1.42 on a CM5): an IPv6 address — nmcli
    refuses it, and the "|| true" in 70_configure_ingest hid that: eth1 kept
    its old address while the WebUI showed the new one; a network or broadcast
    address — nmcli accepts it and eth1 ends up unreachable for the AOI; a
    gateway outside eth1's network — accepted and never used; and a network
    overlapping eth0's: two routes to one subnet, and SMB/WebUI replies to
    eth0's clients leave through eth1."""
    if cfg.get("ETH1_ENABLED", "false") != "true":
        return True, ""
    addr = cfg.get("ETH1_ADDRESS", "")
    try:
        ip = ipaddress.IPv4Address(addr)
        prefix = int(cfg.get("ETH1_PREFIX", "24") or "24")
        net = ipaddress.IPv4Network(f"{addr}/{prefix}", strict=False)
    except ValueError:
        return False, "ETH1_ADDRESS must be an IPv4 address (e.g. 192.168.100.1)"
    if prefix == 32:
        return False, "ETH1_PREFIX /32 leaves no address for the AOI (1-31)"
    error = host_address_error(ip, net)
    if error:
        return False, f"ETH1_ADDRESS: {error}"
    gateway = cfg.get("ETH1_GATEWAY", "")
    if gateway:
        try:
            gw = ipaddress.IPv4Address(gateway)
        except ValueError:
            return False, "ETH1_GATEWAY must be an IPv4 address"
        if gw not in net or gw == ip:
            return False, f"ETH1_GATEWAY {gateway} is not another host in eth1's network {net}"
    for other, what in eth0_networks(cfg):
        if net.overlaps(other):
            return False, (
                f"eth1's network {net} overlaps {what} ({other}). "
                "The AOI link needs a subnet of its own."
            )
    return True, ""


def setup_allowed() -> bool:
    """First-run setup is only reachable until a password exists."""
    return not PASS_FILE.exists()


LOGIN_RATE_LIMIT = 5  # max attempts per window
LOGIN_RATE_WINDOW = 900  # 15 minutes
_login_attempts: dict[str, list[float]] = {}


class WebHandler(BaseHTTPRequestHandler):
    server_version = "VisionWebUI/1.0"
    # Per socket operation. The server is single-threaded: a connection that
    # opened and sent nothing (or stalled mid-body) held every other page
    # forever. A slow but moving upload is unaffected.
    timeout = 30

    def _send_security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; style-src 'unsafe-inline' 'self'; script-src 'self'",
        )

    def send_text(self, text: str, status=200, content_type="text/html; charset=utf-8"):
        data = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, obj: dict, status=200, cookies: list | None = None):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for cookie in cookies or []:
            self.send_header("Set-Cookie", cookie)
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(data)

    def send_error(self, code, message=None, explain=None):
        # API callers parse JSON: the stock HTML error page made the pages'
        # error handling fail on top of the real error, so the operator saw a
        # browser message instead of what went wrong.
        if self.path.startswith("/api/"):
            status = HTTPStatus(code)
            return self.send_json({"ok": False, "error": message or status.phrase}, status=status)
        return super().send_error(code, message, explain)

    def redirect(self, location: str):
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", location)
        self.end_headers()

    def is_authenticated(self) -> bool:
        # Only a session issued to the admin. The export/protected pages hand an
        # operator a token signed with the same secret (user "export"); checking
        # the signature alone let that token, copied into a cookie named
        # "session", open /admin — and with it /api/update, which runs as root.
        return session_user(get_cookie(self.headers, "session")) == "admin"

    def is_export_authenticated(self) -> bool:
        """The export page runs on its own credential, deliberately.

        An operator copying images off the unit should not be handed the admin
        password, and export must not become a weaker way into the same mirror
        than the SMB share — so it takes the SMB password, which they already
        have. An admin session is accepted too, so /export works while logged in.
        """
        if session_user(get_cookie(self.headers, "export_session")) == EXPORT_SESSION_USER:
            return True
        return self.is_authenticated()

    def require_export_csrf(self) -> bool:
        # Either credential's token is fine. Both logins used to share ONE
        # "csrf" cookie: signing in to the admin pages after the SMB-password
        # login (a normal install sequence) overwrote it, and with the export
        # session still valid every save on /protected and /export failed with
        # 403 "CSRF validation failed" — shown in the browser as "body stream
        # already read". The export login now sets its own "export_csrf".
        token = get_cookie(self.headers, "export_session")
        header = self.headers.get("X-CSRF", "")
        if (
            header
            and session_user(token) == EXPORT_SESSION_USER
            and hmac.compare_digest(header, make_csrf(token))
        ):
            return True
        return self.require_csrf()

    def require_csrf(self) -> bool:
        csrf_cookie = get_cookie(self.headers, "csrf")
        if not csrf_cookie:
            return False
        token = get_cookie(self.headers, "session")
        if not token:
            return False
        expected = make_csrf(token)
        header = self.headers.get("X-CSRF", "")
        return (
            bool(header)
            and hmac.compare_digest(header, csrf_cookie)
            and hmac.compare_digest(header, expected)
        )

    def do_GET(self):
        # The landing page and the export flow are reachable before the admin
        # password exists: export has its own credential (the SMB one), so
        # herding an operator into setting an admin password to copy files off
        # would be backwards.
        if self.path in ("/", "/index.html"):
            return self.send_text(self.render_landing())
        if (
            setup_allowed()
            and self.path not in ("/setup", "/setup/")
            and not self.path.startswith("/export")
            and not self.path.startswith("/api/usb-export/")
            and not self.path.startswith("/static/")
        ):
            return self.redirect("/setup")
        if self.path in ("/login", "/login/"):
            return self.send_text(self.render_login())
        if self.path in ("/setup", "/setup/"):
            if not setup_allowed():
                return self.redirect("/login")
            return self.send_text(self.render_setup())
        if self.path.startswith("/static/"):
            return self.serve_static(self.path[len("/static/") :])
        # The export page sits outside the admin wall on its own credential, so
        # an operator never needs the admin password to copy data off the unit.
        if self.path in ("/export", "/export/"):
            if not self.is_export_authenticated():
                return self.send_text(self.render_export_login())
            return self.serve_static("export.html", content_type="text/html; charset=utf-8")
        # Same credential as /export: same audience, same data, and an operator
        # deciding what to keep should not need the admin password either.
        if self.path in ("/protected", "/protected/"):
            if not self.is_export_authenticated():
                return self.send_text(self.render_export_login(target="/protected"))
            return self.serve_static("protected.html", content_type="text/html; charset=utf-8")
        if self.path.startswith("/api/protected"):
            if not self.is_export_authenticated():
                return self.send_json({"ok": False, "error": "unauthorized"}, status=401)
            return self.send_json(get_protected_status())
        if self.path.startswith("/api/usb-export/"):
            if not self.is_export_authenticated():
                return self.send_json({"ok": False, "error": "unauthorized"}, status=401)
            return self.handle_export_get()
        if not self.is_authenticated():
            return self.redirect("/login")
        if self.path in ("/admin", "/admin/"):
            return self.serve_static("index.html", content_type="text/html; charset=utf-8")
        if self.path.startswith("/api/status"):
            cfg = parse_config(load_config_text())
            iface = cfg.get("SMB_BIND_INTERFACE", "eth0")
            active_lv = get_active_usb_lv()
            data = {
                "services": get_service_status(),
                "active_usb_lv": active_lv,
                "active_usb_usage": get_usb_lv_usage(active_lv),
                "network": get_network_config(iface),
                "sync_timer": get_sync_timer_status(),
                "sync_service": get_sync_service_status(),
                "mirror_usage": get_disk_usage("/srv/vision_mirror"),
                "nvme": get_nvme_smart(),
                "build": get_build_stamp(),
            }
            return self.send_json(data)
        if self.path.startswith("/api/log-services"):
            return self.send_json({"services": LOG_SERVICES})
        if self.path.startswith("/api/logs"):
            query = urlparse(self.path).query
            params = parse_qs(query)
            service = params.get("service", [""])[0]
            lines = params.get("lines", ["200"])[0]
            if service not in LOG_SERVICES:
                return self.send_json({"error": "invalid service"}, status=400)
            try:
                lines_int = int(lines)
            except ValueError:
                return self.send_json({"error": "invalid lines"}, status=400)
            lines_int = max(10, min(lines_int, 2000))
            code, out, err = run_cmd(
                [
                    "journalctl",
                    "-u",
                    service,
                    "-n",
                    str(lines_int),
                    "--no-pager",
                    "--output",
                    "short-iso",
                ],
                timeout=10,
            )
            if code != 0:
                return self.send_json({"error": err or out or "failed to read logs"}, status=500)
            return self.send_json({"service": service, "lines": lines_int, "text": out})
        if self.path.startswith("/api/health"):
            return self.send_json(read_health())
        if self.path == "/api/config":
            cfg = parse_config(load_config_text())
            payload = {k: cfg.get(k, "") for k in ALLOWED_CONFIG_KEYS}
            return self.send_json(payload)
        if self.path.startswith("/api/nas-creds"):
            if NAS_CREDS_SHADOW.exists():
                creds = parse_nas_creds(NAS_CREDS_SHADOW.read_text(encoding="utf-8"))
            elif NAS_CREDS.exists():
                creds = parse_nas_creds(NAS_CREDS.read_text(encoding="utf-8"))
            else:
                creds = {"username": "", "password": "", "domain": ""}
            return self.send_json(creds)
        if self.path.startswith("/api/network"):
            return self.send_json(get_network_setting(parse_config(load_config_text())))
        if self.path.startswith("/api/me"):
            token = get_cookie(self.headers, "session")
            expiry = None
            if token:
                try:
                    raw = base64.urlsafe_b64decode(token.encode("ascii")).decode("utf-8")
                    _user, exp_str, _nonce, _sig = raw.split("|", 3)
                    expiry = int(exp_str)
                except Exception:
                    pass
            return self.send_json({"ok": True, "session_expires": expiry})
        if self.path.startswith("/api/time"):
            code, out, err = run_cmd(["/usr/bin/timedatectl", "status"])
            if code != 0:
                return self.send_json({"status": err or "failed to read time"}, status=500)
            server_time = time.strftime("%Y-%m-%d %H:%M:%S")
            result = {"status": out, "server_time": server_time}
            code2, out2, _ = run_cmd(["/usr/bin/timedatectl", "show"])
            if code2 == 0:
                props = {}
                for line in out2.splitlines():
                    if "=" in line:
                        k, v = line.split("=", 1)
                        props[k] = v
                result["ntp_enabled"] = props.get("NTP", "n/a")
                result["ntp_synced"] = props.get("NTPSynchronized", "n/a")
                result["timezone"] = props.get("Timezone", "n/a")
                cfg = parse_config(load_config_text())
                result["rtc_enabled"] = cfg.get("RTC_ENABLED", "false")
                result["rtc_device"] = cfg.get("RTC_DEVICE", "/dev/rtc0")
            return self.send_json(result)
        if self.path.startswith("/api/usb-health"):
            health_path = STATE_DIR / "usb-fsck.json"
            if health_path.exists():
                try:
                    return self.send_json(json.loads(health_path.read_text(encoding="utf-8")))
                except json.JSONDecodeError:
                    return self.send_json({"error": "invalid usb-fsck.json"})
            return self.send_json({"lvs": [], "ts": ""})
        if self.path.startswith("/api/nas-status"):
            status_path = STATE_DIR / "nas-sync-status.json"
            if status_path.exists():
                try:
                    return self.send_json(json.loads(status_path.read_text(encoding="utf-8")))
                except json.JSONDecodeError:
                    return self.send_json({"status": "unknown"})
            return self.send_json({"status": "no data"})
        if self.path.startswith("/api/config/export"):
            config_text = load_config_text()
            data = config_text.encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", "attachment; filename=vision-gw.conf")
            self.send_header("Content-Length", str(len(data)))
            self._send_security_headers()
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.startswith("/api/config/bundle"):
            with POST_LOCK:  # one fixed output file in /run
                return self.handle_bundle_export()
        if self.path.startswith("/api/maintenance-mode"):
            return self.send_json({"enabled": MAINT_MODE_FLAG.exists()})
        if self.path.startswith("/api/update/status"):
            history_path = STATE_DIR / "update-history.json"
            history = []
            if history_path.exists():
                import contextlib

                with contextlib.suppress(json.JSONDecodeError):
                    history = json.loads(history_path.read_text(encoding="utf-8"))
            return self.send_json({"history": history})
        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_POST(self):
        # One change at a time (pages and status reads run alongside, see main).
        with POST_LOCK:
            return self._do_post()

    def _do_post(self):
        # Every handler reads exactly Content-Length bytes: a negative one was
        # read(-1) — until the client closes — and this server is single-
        # threaded, so one such request (no login needed) stalled every page.
        try:
            content_length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            content_length = -1
        if content_length < 0:
            self.send_error(HTTPStatus.BAD_REQUEST, "invalid Content-Length")
            return
        if self.path == "/api/update":
            max_size = MAX_UPDATE_SIZE
        elif self.path == "/api/config/bundle/plan":
            max_size = MAX_BUNDLE_SIZE
        else:
            max_size = MAX_BODY_SIZE
        if content_length > max_size:
            self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Request body too large")
            return
        # The export/protected flow runs on the SMB password and must work before
        # an admin password exists — exactly as do_GET already lets it.
        export_flow = (
            self.path in ("/export", "/export/", "/protected", "/protected/", "/api/protected")
            or self.path.startswith("/api/usb-export/")
        )
        if setup_allowed() and self.path not in ("/setup", "/setup/") and not export_flow:
            return self.redirect("/setup")
        if self.path in ("/login", "/login/"):
            return self.handle_login()
        if self.path in ("/export", "/export/"):
            return self.handle_export_login()
        if self.path in ("/protected", "/protected/"):
            return self.handle_export_login(target="/protected")
        if self.path in ("/setup", "/setup/"):
            if not setup_allowed():
                # Never allow an unauthenticated password reset once configured.
                log("rejected /setup POST: password already configured")
                return self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            if not mirror_mounted():
                # webui.passwd lives on the NVMe: without it mounted, "setup" is
                # open to anyone and the password would land on tmpfs anyway.
                log("rejected /setup POST: NVMe storage not mounted")
                return self.send_text(self.render_setup(STORAGE_MISSING), status=503)
            return self.handle_setup()
        if self.path == "/api/protected":
            if not self.is_export_authenticated():
                return self.send_error(HTTPStatus.UNAUTHORIZED, "Unauthorized")
            if not self.require_export_csrf():
                return self.send_error(HTTPStatus.FORBIDDEN, "CSRF validation failed")
            if not mirror_mounted():
                return self.send_json({"ok": False, "error": STORAGE_MISSING}, status=503)
            return self.handle_protected_save()
        if self.path.startswith("/api/usb-export/"):
            if not self.is_export_authenticated():
                return self.send_error(HTTPStatus.UNAUTHORIZED, "Unauthorized")
            if not self.require_export_csrf():
                return self.send_error(HTTPStatus.FORBIDDEN, "CSRF validation failed")
            if self.path == "/api/usb-export/copy":
                return self.handle_usb_copy()
            if self.path == "/api/usb-export/mkdir":
                return self.handle_usb_mkdir()
            if self.path == "/api/usb-export/eject":
                with require_lock():
                    code, out, err = eject_usb()
                    if code != 0:
                        return self.send_json({"ok": False, "error": err or out}, status=400)
                    log("usb-export: drive ejected from the WebUI")
                    return self.send_json({"ok": True})
            return self.send_error(HTTPStatus.NOT_FOUND, "Not found")
        if not self.is_authenticated():
            return self.send_error(HTTPStatus.UNAUTHORIZED, "Unauthorized")
        if self.path.startswith("/api/") and not self.require_csrf():
            return self.send_error(HTTPStatus.FORBIDDEN, "CSRF validation failed")
        if self.path in STATE_WRITING_POSTS and not mirror_mounted():
            return self.send_json({"ok": False, "error": STORAGE_MISSING}, status=503)
        if self.path == "/api/config":
            return self.handle_config_update()
        if self.path == "/api/nas-creds":
            return self.handle_nas_creds()
        if self.path == "/api/apply":
            return self.handle_apply()
        if self.path == "/api/password/webui":
            return self.handle_webui_password()
        if self.path == "/api/password/smb":
            return self.handle_smb_password()
        if self.path == "/api/password/ftp":
            return self.handle_ftp_password()
        if self.path == "/api/maintenance/wipe":
            return self.handle_maintenance(["wipe"])
        if self.path == "/api/maintenance/factory-reset":
            return self.handle_maintenance(["factory-reset"])
        if self.path == "/api/maintenance/resize":
            return self.handle_maintenance(["resize"])
        if self.path == "/api/maintenance/restore-defaults":
            return self.handle_maintenance(["restore-defaults"])
        if self.path == "/api/maintenance/clone-usb-format":
            return self.handle_maintenance(["clone-usb-format"])
        if self.path == "/api/maintenance/shutdown":
            return self.handle_maintenance(["shutdown"])
        if self.path == "/api/maintenance/rotate":
            return self.handle_maintenance(["rotate"])
        if self.path == "/api/maintenance/sync":
            return self.handle_maintenance(["sync"])
        if self.path == "/api/network":
            return self.handle_network()
        if self.path == "/api/time":
            return self.handle_time()
        if self.path == "/api/config/import":
            return self.handle_config_import()
        if self.path == "/api/maintenance-mode":
            return self.handle_maintenance_mode()
        if self.path == "/api/update":
            return self.handle_update()
        if self.path == "/api/config/bundle/plan":
            return self.handle_bundle_plan()
        if self.path == "/api/config/bundle/provision":
            return self.handle_bundle_provision()
        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def handle_login(self):
        client_ip = self.client_address[0]
        now = time.time()
        attempts = _login_attempts.get(client_ip, [])
        attempts = [t for t in attempts if now - t < LOGIN_RATE_WINDOW]
        _login_attempts[client_ip] = attempts
        if len(attempts) >= LOGIN_RATE_LIMIT:
            log(f"login rate limited: {client_ip}")
            self.send_text(self.render_login("Too many attempts. Try again later."), status=429)
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        params = parse_qs(body)
        password = params.get("password", [""])[0]
        if verify_password(password):
            _login_attempts.pop(client_ip, None)
            token = make_session("admin")
            csrf = make_csrf(token)
            self.send_response(HTTPStatus.SEE_OTHER)
            self.send_header("Set-Cookie", f"session={token}; HttpOnly; Path=/; SameSite=Strict")
            self.send_header("Set-Cookie", f"csrf={csrf}; Path=/; SameSite=Strict")
            # Straight to the config UI: "/" is now the landing page, and being
            # bounced back to a chooser right after signing in reads as a failure.
            self.send_header("Location", "/admin")
            self.end_headers()
            log("login success")
        else:
            attempts.append(now)
            log(f"login failed ({len(attempts)}/{LOGIN_RATE_LIMIT})")
            self.send_text(self.render_login("Invalid password"), status=401)

    def handle_setup(self):
        if not setup_allowed():
            return self.send_error(HTTPStatus.NOT_FOUND, "Not found")
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return self.send_text(self.render_setup())
        body = self.rfile.read(length).decode("utf-8")
        params = parse_qs(body)
        password = params.get("password", [""])[0]
        confirm = params.get("confirm", [""])[0]
        if not password or password != confirm:
            return self.send_text(self.render_setup("Passwords do not match"), status=400)
        store_password(password)
        log("initial password set")
        return self.redirect("/login")

    def handle_config_update(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        updates = {k: str(v) for k, v in data.items() if k in ALLOWED_CONFIG_KEYS}
        ok, error = validate_config_updates(updates)
        if not ok:
            return self.send_json({"ok": False, "error": error}, status=400)
        base_text = load_config_text()
        if any(k.startswith("ETH1_") for k in updates):
            ok, error = validate_eth1({**parse_config(base_text), **updates})
            if not ok:
                return self.send_json({"ok": False, "error": error}, status=400)
        new_text = update_config_file(base_text, updates)
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Not last-good: apply-shadow-config promotes it only after the config
        # applied cleanly — written here, a config that fails to apply became
        # the "known good" rollback target too.
        atomic_write(SHADOW_CONF, new_text)
        log(f"config updated: {', '.join(sorted(updates.keys()))}")
        return self.send_json({"ok": True})

    def end_other_sessions(self) -> list:
        """After a password change: a new session key, so every session signed
        with the old one — an 8 h admin or export login by whoever knew the old
        password — ends now. The admin who made the change keeps working: the
        returned cookies re-issue their session under the new key."""
        rotate_secret()
        token = make_session("admin")
        return [
            f"session={token}; HttpOnly; Path=/; SameSite=Strict",
            f"csrf={make_csrf(token)}; Path=/; SameSite=Strict",
        ]

    def local_address(self) -> str:
        """The unit's address this request came in on ("" if unknown)."""
        try:
            return str(self.connection.getsockname()[0]).removeprefix("::ffff:")
        except (OSError, AttributeError, IndexError):
            return ""

    def came_in_on(self, iface: str) -> bool:
        local = self.local_address()
        return bool(local) and local in {str(i.ip) for i in iface_ipv4(iface)}

    @staticmethod
    def admin_url(address: str) -> str:
        port = parse_config(load_config_text()).get("WEBUI_PORT", "80") or "80"
        return f"http://{address}{'' if port == '80' else ':' + port}/admin"

    def eth1_move_target(self):
        """None when this request did not come in on eth1's address, else where
        that address goes after the apply: the new address, or "" if eth1 is
        being switched off."""
        if not self.came_in_on("eth1"):
            return None
        local = self.local_address()
        cfg = parse_config(load_config_text())
        if cfg.get("ETH1_ENABLED", "false") != "true":
            return ""
        new = cfg.get("ETH1_ADDRESS", "")
        return new if new and new != local else None

    def handle_apply(self):
        with require_lock():
            gh = get_gateway_home()
            target = self.eth1_move_target()
            if target is not None:
                # This request came in on the eth1 address the apply takes away:
                # the reply would never arrive (seen live: the browser still
                # waiting after 90 s, the operator not knowing the change took).
                # Answer first, apply two seconds later in its own unit.
                code, out, err = run_cmd([*DEFERRED_RUN, f"{gh}/scripts/apply-shadow-config.sh"])
                log(f"apply-config deferred (request on eth1, moving to {target or 'off'}) rc={code} {err}")
                if code != 0:
                    return self.send_json({"ok": False, "error": err or out}, status=500)
                return self.send_json({"ok": True, "reconnect": self.admin_url(target) if target else ""})
            code, out, err = run_privileged([f"{gh}/scripts/apply-shadow-config.sh"])
            log(f"apply-config rc={code} out={out} err={err}")
            if code != 0:
                return self.send_json({"ok": False, "error": apply_error(err or out)}, status=500)
            return self.send_json({"ok": True})

    def handle_webui_password(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        password = data.get("password", "")
        confirm = data.get("confirm", "")
        if not password or password != confirm:
            return self.send_json({"ok": False, "error": "passwords do not match"}, status=400)
        if not is_valid_password(password):
            return self.send_json({"ok": False, "error": "invalid password"}, status=400)
        store_password(password)
        log("webui password changed")
        return self.send_json({"ok": True}, cookies=self.end_other_sessions())

    def handle_smb_password(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        password = data.get("password", "")
        confirm = data.get("confirm", "")
        if not password or password != confirm:
            return self.send_json({"ok": False, "error": "passwords do not match"}, status=400)
        if not is_valid_password(password):
            return self.send_json({"ok": False, "error": "invalid password"}, status=400)
        cfg = parse_config(load_config_text())
        smb_user = cfg.get("SMB_USER", "smbuser")
        input_text = f"{password}\n{password}\n"
        code, out, err = run_privileged(
            ["/usr/bin/smbpasswd", "-s", "-a", smb_user],
            input_text=input_text,
        )
        if code != 0:
            return self.send_json({"ok": False, "error": err or out}, status=500)
        code, out, err = run_privileged(["/usr/bin/smbpasswd", "-e", smb_user])
        if code != 0:
            return self.send_json(
                {"ok": False, "error": f"SMB account not enabled: {err or out}"}, status=500
            )
        # Mirror FTP (eth0) authenticates as this same Unix account via PAM, not
        # Samba's own passdb -- and /etc/shadow lives on the overlay root, so
        # unlike passdb.tdb (bind-mounted onto persistent storage by
        # 50_configure_samba.sh) it does NOT survive a reboot. Persist on the
        # NVMe so 80_configure_mirror_ftp.sh can re-apply it (chpasswd) on
        # every boot -- same pattern as ftp.creds for the ingest FTP user.
        atomic_write(STATE_DIR / "smb_unix.creds", f"password={password}\n", 0o600)
        # Checked: unchecked, a failure here reported "OK" while the mirror FTP
        # login kept the old password.
        code, out, err = run_privileged(["/usr/sbin/chpasswd"], input_text=f"{smb_user}:{password}\n")
        if code != 0:
            return self.send_json(
                {"ok": False, "error": f"SMB password set, but the mirror FTP login was not: {err or out}"},
                status=500,
            )
        log(f"smb password changed for {smb_user}")
        return self.send_json({"ok": True}, cookies=self.end_other_sessions())

    def handle_ftp_password(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        password = data.get("password", "")
        confirm = data.get("confirm", "")
        if not password or password != confirm:
            return self.send_json({"ok": False, "error": "passwords do not match"}, status=400)
        if not is_valid_password(password):
            return self.send_json({"ok": False, "error": "invalid password"}, status=400)
        cfg = parse_config(load_config_text())
        ftp_user = cfg.get("FTP_USER", "aoiftp")
        # Persist on the NVMe (overlay-safe; re-applied on boot by 70_configure_ingest).
        atomic_write(STATE_DIR / "ftp.creds", f"password={password}\n", 0o600)
        # Apply now if the ingest user already exists (otherwise 70_configure_ingest
        # applies it when ingest is enabled) — and report it if that fails.
        try:
            pwd.getpwnam(ftp_user)
        except KeyError:
            log(f"ftp password stored; {ftp_user} does not exist yet (applied when ingest is enabled)")
            return self.send_json({"ok": True})
        code, out, err = run_privileged(["/usr/sbin/chpasswd"], input_text=f"{ftp_user}:{password}\n")
        if code != 0:
            return self.send_json({"ok": False, "error": f"FTP password not applied: {err or out}"}, status=500)
        log(f"ftp password changed for {ftp_user}")
        return self.send_json({"ok": True})

    def handle_network(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        with require_lock():
            cfg = parse_config(load_config_text())
            error, record = validate_network(cfg, data)
            if error:
                return self.send_json({"ok": False, "error": error}, status=400)
            before = read_network_state()
            on_iface = self.came_in_on(record["interface"])
            atomic_write(NETWORK_STATE, json.dumps(record), 0o600)
            # Answer first, apply two seconds later in its own unit (see
            # NETWORK_RESULT). A fixed unit name: a second change while one is
            # still being applied is refused instead of racing it.
            gh = get_gateway_home()
            code, out, err = run_cmd([
                *DEFERRED_RUN, f"--unit={NETWORK_APPLY_UNIT}", f"{gh}/scripts/apply-network.sh",
            ])
            log(f"network saved: {record['method']} {record['address']}/{record['prefix']}; "
                f"apply scheduled rc={code} {err}")
            if code != 0:
                return self.send_json({
                    "ok": False,
                    "error": "Saved, but not applied — a previous network change may still be "
                             f"in progress; try again shortly ({err or out})",
                }, status=500)
            reply = {"ok": True, "since": int(time.time())}
            if on_iface:
                # This browser reaches the unit through the address being changed.
                if record["method"] == "manual":
                    if record["address"] != self.local_address():
                        reply["reconnect"] = self.admin_url(record["address"])
                elif before.get("method") == "manual":
                    reply["reconnect"] = ""
                    reply["hint"] = self.admin_url(f"{cfg.get('NETBIOS_NAME', 'CITOSTORE')}.local")
                    reply["direct"] = self.admin_url(f"{cfg.get('MDNS_DIRECT_SUBNET', '10.10.10')}.1")
            return self.send_json(reply)

    def handle_nas_creds(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        creds = {
            "username": str(data.get("username", "")).strip(),
            "password": str(data.get("password", "")).strip(),
            "domain": str(data.get("domain", "")).strip(),
        }
        if creds["username"] == "" and creds["password"] == "" and creds["domain"] == "":
            return self.send_json({"ok": True})
        # These become username=/password=/domain= lines in a mount.cifs
        # credentials file; a control char (newline) would inject extra lines.
        for field in creds.values():
            if field and not (len(field) <= MAX_PASSWORD_LEN and field.isprintable()):
                return self.send_json({"ok": False, "error": "invalid NAS credentials"}, status=400)
        atomic_write(NAS_CREDS_SHADOW, render_nas_creds(creds), 0o600)
        log("nas creds updated (shadow)")
        return self.send_json({"ok": True})

    def handle_time(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        value = str(data.get("time", "")).strip()
        if not value:
            return self.send_json({"ok": False, "error": "time is required"}, status=400)
        with require_lock():
            code, out, err = set_system_time(value)
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=500)
            gh = get_gateway_home()
            code, out, err = run_privileged([f"{gh}/scripts/rtc-sync.sh", "--systohc"])
            if code != 0:
                log(f"system time set: {value}, but the RTC write failed: {err or out}")
                return self.send_json(
                    {"ok": False, "error": "time set, but not saved to the RTC (lost at power-off): "
                     + (err or out)},
                    status=500,
                )
            log(f"system time set: {value} (ntp disabled)")
            return self.send_json({"ok": True})

    def handle_export_get(self):
        if self.path.startswith("/api/usb-export/status"):
            return self.send_json(get_usb_export_status())
        if self.path.startswith("/api/usb-export/list"):
            params = parse_qs(urlparse(self.path).query)
            try:
                return self.send_json(
                    list_export_dir(
                        params.get("root", ["mirror"])[0], params.get("path", [""])[0]
                    )
                )
            except (ValueError, OSError) as exc:
                return self.send_json({"ok": False, "error": str(exc)}, status=400)
        if self.path.startswith("/api/usb-export/job"):
            return self.send_json(get_usb_copy_status())
        return self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def handle_export_login(self, target: str = "/export"):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        password = parse_qs(body).get("password", [""])[0]
        # Same throttle as the admin login (separate bucket): the SMB password
        # guards the same images, and smbclient answers a guess in ~44 ms.
        key = f"export:{self.client_address[0]}"
        now = time.time()
        attempts = [t for t in _login_attempts.get(key, []) if now - t < LOGIN_RATE_WINDOW]
        _login_attempts[key] = attempts
        if len(attempts) >= LOGIN_RATE_LIMIT:
            log(f"export login rate limited: {self.client_address[0]}")
            return self.send_text(
                self.render_export_login(error=True, target=target), status=429
            )
        if not verify_smb_password(password):
            attempts.append(now)
            log(f"export login rejected ({len(attempts)}/{LOGIN_RATE_LIMIT})")
            return self.send_text(
                self.render_export_login(error=True, target=target), status=401
            )
        _login_attempts.pop(key, None)
        token = make_session(EXPORT_SESSION_USER)
        log("export login accepted")
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", target)
        self.send_header(
            "Set-Cookie",
            f"export_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age={SESSION_TTL_SEC}",
        )
        self.send_header(
            "Set-Cookie",
            f"export_csrf={make_csrf(token)}; SameSite=Strict; Path=/; Max-Age={SESSION_TTL_SEC}",
        )
        self.end_headers()

    def handle_usb_mkdir(self):
        length = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        name = str(data.get("name", "")).strip()
        # A name, not a path: no separators, no traversal, nothing hidden.
        if not name or name in (".", "..") or "/" in name or "\\" in name:
            return self.send_json({"ok": False, "error": "invalid folder name"}, status=400)
        if not name.isprintable() or len(name) > 128:
            return self.send_json({"ok": False, "error": "invalid folder name"}, status=400)
        with require_lock():
            try:
                parent = resolve_export_path("usb", str(data.get("path", "")))
                target = resolve_export_path(
                    "usb", f"{data.get('path', '')}/{name}".strip("/")
                )
            except (ValueError, OSError) as exc:
                return self.send_json({"ok": False, "error": str(exc)}, status=400)
            if not usb_drive_mounted() or not parent.is_dir():
                return self.send_json({"ok": False, "error": "no USB drive here"}, status=400)
            if target.exists():
                return self.send_json({"ok": False, "error": "already exists"}, status=400)
            code, out, err = run_privileged(["/bin/mkdir", "--", str(target)])
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=500)
            log(f"usb-export: folder created: {name}")
            return self.send_json({"ok": True})

    def handle_protected_save(self):
        length = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        paths = data.get("paths")
        if not isinstance(paths, list):
            return self.send_json({"ok": False, "error": "paths must be a list"}, status=400)
        with require_lock():
            try:
                code, out, err = set_protected_paths(paths)
            except (ValueError, OSError) as exc:
                return self.send_json({"ok": False, "error": str(exc)}, status=400)
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=500)
            log(f"retention: {len(paths)} folder(s) protected")
            return self.send_json({"ok": True})

    def handle_usb_copy(self):
        length = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        sources = data.get("items") or []
        if not isinstance(sources, list):
            return self.send_json({"ok": False, "error": "items must be a list"}, status=400)
        with require_lock():
            try:
                code, out, err = start_usb_copy(sources, str(data.get("dest", "")))
            except (ValueError, OSError) as exc:
                return self.send_json({"ok": False, "error": str(exc)}, status=400)
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=400)
            log(f"usb-export: copy started ({len(sources)} item(s))")
            return self.send_json({"ok": True})

    def handle_maintenance(self, action):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        with require_lock():
            gh = get_gateway_home()
            if action == ["wipe"]:
                args = ["/bin/systemctl", "start", "vision-wipe.service"]
            elif action == ["factory-reset"]:
                # Wipes the whole NVMe and reboots — starting a transient-free
                # service (like wipe) so it survives this request ending and the
                # WebUI going down with the reboot. --no-block so the HTTP reply
                # is sent before the teardown begins.
                args = ["/bin/systemctl", "--no-block", "start", "vision-factory-reset.service"]
            elif action == ["resize"]:
                size = str(data.get("size", "")).strip().upper()
                if not LV_SIZE_RE.match(size):
                    return self.send_json(
                        {"ok": False, "error": "size must look like 100G or 512M"}, status=400
                    )
                args = [
                    f"{gh}/scripts/resize-usb-lvs.sh",
                    "--size",
                    size,
                    "--force",
                    "--update-config",
                ]
            elif action == ["shutdown"]:
                args = ["/usr/sbin/shutdown", "-h", "now"]
            elif action == ["restore-defaults"]:
                args = [f"{gh}/scripts/restore-defaults.sh", "--i-know-what-im-doing"]
            elif action == ["clone-usb-format"]:
                args = ["/bin/systemctl", "start", "vision-usb-format.service"]
            elif action == ["rotate"]:
                Path("/run/vision-rotate.state").write_text(
                    "state=panic\nreason=webui\n", encoding="utf-8"
                )
                args = ["/bin/systemctl", "start", "vision-rotator.service"]
            elif action == ["sync"]:
                args = ["/bin/systemctl", "start", "vision-sync.service"]
            else:
                return self.send_json({"ok": False, "error": "unknown action"}, status=400)
            # Direct-script actions mutate /etc, /dev and LVM metadata, so they must
            # run outside this service's ProtectSystem=strict sandbox. systemctl/
            # shutdown actions only talk to PID 1 over D-Bus and work in-sandbox.
            privileged = action and action[0] in ("resize", "restore-defaults")
            runner = run_privileged if privileged else run_cmd
            code, out, err = runner(args, timeout=3600)
            log(f"maintenance {action} rc={code} out={out} err={err}")
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=500)
            return self.send_json({"ok": True})

    def handle_update(self):
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > MAX_UPDATE_SIZE:
            return self.send_json(
                {"ok": False, "error": "update too large"},
                status=413,
            )
        body = self.rfile.read(content_length)
        # An install still running (one that outlasted this request's wait): a
        # retry deleted the directory it ran from, and the archive persisted
        # for every later boot was then the retry, never applied.
        code, _, _ = run_cmd(["/bin/systemctl", "is-active", "--quiet", "vision-update.service"])
        if code == 0:
            return self.send_json(
                {"ok": False, "error": "an update is still being installed — wait for it to finish"},
                status=409,
            )
        staging = STATE_DIR / "update-staging"
        if staging.exists():
            import shutil

            shutil.rmtree(staging)
        staging.mkdir(parents=True, exist_ok=True)
        archive = staging / "update.tar.gz"
        archive.write_bytes(body)

        # Every refusal before apply-update.sh runs also goes into the history:
        # that list is what the operator checks, and the status line is
        # overwritten by the next status poll.
        def reject(error: str, version: str = "unknown"):
            record_update_history(version, f"rejected: {error}")
            return self.send_json({"ok": False, "error": error}, status=400)

        # --no-same-owner: the WebUI runs without CAP_CHOWN, so restoring a
        # package's foreign owner uid (e.g. the build host's) fails extraction.
        code, out, err = run_cmd(
            ["tar", "xzf", str(archive), "--no-same-owner", "-C", str(staging)]
        )
        if code != 0:
            archive.unlink(missing_ok=True)
            return reject(f"extraction failed: {err.strip()[:200]}")
        manifest = staging / "manifest.json"
        if not manifest.exists():
            return reject("missing manifest.json")
        install_sh = staging / "install.sh"
        if not install_sh.exists():
            return reject("missing install.sh")
        try:
            meta = json.loads(manifest.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return reject("invalid manifest.json")
        version = meta.get("version", "unknown")
        # Waits for install.sh (bounded by the unit: 15 min); 120 s answered
        # "no answer" while a long install went on.
        code, _, err = run_cmd(["/bin/systemctl", "start", "vision-update.service"], timeout=960)
        if code != 0:
            msg = err or "failed to start update"
            return self.send_json({"ok": False, "error": msg}, status=500)
        log(f"update {version} staged and applied")
        return self.send_json({"ok": True, "version": version})

    def handle_config_import(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        config_text = data.get("config", "")
        if not config_text.strip():
            return self.send_json({"ok": False, "error": "empty config"}, status=400)
        normalized, err = validate_import_config(config_text)
        if err:
            return self.send_json({"ok": False, "error": err}, status=400)
        parsed = parse_config_text(normalized)
        # The same eth1 checks as a WebUI save: 70_configure_ingest applies
        # whatever the file says on the next Save + Apply or boot.
        ok, err = validate_eth1(parsed)
        if not ok:
            return self.send_json({"ok": False, "error": f"imported config: {err}"}, status=400)
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Atomic (with fsync), and last-good is left alone: it is what
        # health-check rolls back to if this file turns out bad, so it must not
        # become this file too.
        atomic_write(SHADOW_CONF, normalized)
        log(f"config imported ({len(parsed)} keys)")
        return self.send_json(
            {"ok": True, "message": "Config imported — press Save + Apply in any section or restart to apply it"}
        )

    def handle_bundle_export(self):
        # Full portable unit definition: config + secrets + Samba passdb +
        # aoi_settings, as a single .citostore file (a tar.gz under the hood).
        gh = get_gateway_home()
        out = Path("/run/citostore-config.citostore")
        code, _, err = run_cmd(["/bin/bash", f"{gh}/scripts/export-config-bundle.sh", str(out)])
        if code != 0 or not out.exists():
            return self.send_json({"ok": False, "error": err or "export failed"}, status=500)
        data = out.read_bytes()
        out.unlink(missing_ok=True)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header(
            "Content-Disposition", "attachment; filename=citostore-config.citostore"
        )
        self.send_header("Content-Length", str(len(data)))
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(data)

    def handle_bundle_plan(self):
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            return self.send_json({"ok": False, "error": "empty bundle"}, status=400)
        body = self.rfile.read(length)
        PROVISION_STAGE.mkdir(parents=True, exist_ok=True)
        BUNDLE_STAGED.write_bytes(body)
        error = bundle_config_error(BUNDLE_STAGED)
        if error:
            BUNDLE_STAGED.unlink(missing_ok=True)
            return self.send_json({"ok": False, "error": error}, status=400)
        gh = get_gateway_home()
        code, out, err = run_cmd(
            ["/bin/bash", f"{gh}/scripts/provision-from-bundle.sh", str(BUNDLE_STAGED), "--plan"]
        )
        if code != 0:
            return self.send_json(
                {"ok": False, "error": err or out or "invalid bundle"}, status=400
            )
        try:
            plan = json.loads(out)
        except json.JSONDecodeError:
            return self.send_json({"ok": False, "error": "plan parse error"}, status=500)
        log("config bundle uploaded and planned")
        return self.send_json({"ok": True, "plan": plan})

    def handle_bundle_provision(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        data = json.loads(body or "{}")
        if not data.get("confirm"):
            return self.send_json({"ok": False, "error": "confirmation required"}, status=400)
        if not BUNDLE_STAGED.exists():
            return self.send_json(
                {"ok": False, "error": "no staged bundle; upload and review the plan first"},
                status=400,
            )
        code, _, err = run_cmd(
            ["/bin/systemctl", "start", "--no-block", "vision-provision.service"]
        )
        if code != 0:
            return self.send_json(
                {"ok": False, "error": err or "failed to start provisioning"}, status=500
            )
        log("provisioning started from staged bundle (DESTRUCTIVE)")
        return self.send_json(
            {
                "ok": True,
                "message": "Provisioning started; the WebUI restarts in about a minute.",
            }
        )

    def handle_maintenance_mode(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        enabled = data.get("enabled", False)
        # Pause everything that syncs or rotates — including the fast 10 s sync
        # timer, which kept syncing through "maintenance mode" — but resume only
        # the timers that are on by design: the rotator timer is off by design
        # (the rotator runs after each sync), and the monitor starts the fast
        # timer itself when the AOI is writing.
        stop_timers = ["vision-sync.timer", "vision-sync-fast.timer",
                       "vision-monitor.timer", "vision-rotator.timer"]
        resume_timers = ["vision-sync.timer", "vision-monitor.timer"]
        with require_lock():
            if enabled:
                MAINT_MODE_FLAG.write_text("1", encoding="utf-8")
                for t in stop_timers:
                    run_cmd(["/bin/systemctl", "stop", t])
                log("maintenance mode enabled")
            else:
                MAINT_MODE_FLAG.unlink(missing_ok=True)
                for t in resume_timers:
                    run_cmd(["/bin/systemctl", "start", t])
                log("maintenance mode disabled")
        return self.send_json({"ok": True, "enabled": enabled})

    def serve_static(self, name: str, content_type: str | None = None):
        path = (STATIC_DIR / name).resolve()
        if STATIC_DIR not in path.parents and path != STATIC_DIR:
            return self.send_error(HTTPStatus.FORBIDDEN, "forbidden")
        if not path.exists():
            return self.send_error(HTTPStatus.NOT_FOUND, "not found")
        data = path.read_bytes()
        if not content_type:
            if path.suffix == ".js":
                content_type = "application/javascript; charset=utf-8"
            elif path.suffix == ".css":
                content_type = "text/css; charset=utf-8"
            else:
                content_type = "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        # The admin, export and protected pages are served from here: without
        # the CSP they were the only pages with none (no inline scripts in them).
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(data)

    def render_landing(self) -> str:
        """Front door. Deliberately unauthenticated and deliberately empty of facts.

        Its whole job is to send the two audiences to the right place — an
        operator who wants files off the unit should not land on an admin login.
        It therefore shows the unit's name (already broadcast over mDNS/NetBIOS,
        so not a disclosure) and nothing else: no status, no config, no hint of
        what is stored here.
        """
        cfg = parse_config(load_config_text())
        name = html.escape(str(cfg.get("NETBIOS_NAME", "CitoStore")))
        return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{name} - CitoStore</title>
  <style>
    body {{ font-family: system-ui, sans-serif; margin: 0; background: #f4f6f8; color: #1c2530; }}
    .wrap {{ max-width: 720px; margin: 0 auto; padding: 64px 20px; }}
    h1 {{ margin: 0 0 4px; font-size: 30px; }}
    h1 .accent {{ color: #1e8e5a; }}
    .unit {{ color: #667; margin: 0 0 40px; font-size: 15px; }}
    .cards {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px; }}
    a.card {{ display: block; padding: 26px 24px; background: #fff; border: 1px solid #e2e6ea;
      border-radius: 12px; text-decoration: none; color: inherit;
      transition: border-color .15s, box-shadow .15s, transform .15s; }}
    a.card:hover {{ border-color: #1e8e5a; box-shadow: 0 8px 24px rgba(0,0,0,.09); transform: translateY(-2px); }}
    .card h2 {{ margin: 0 0 8px; font-size: 19px; }}
    .card p {{ margin: 0; color: #667; font-size: 14px; line-height: 1.5; }}
    @media (max-width: 860px) {{ .cards {{ grid-template-columns: 1fr; }} }}
  </style>
</head>
<body>
  <div class="wrap">
    <h1><span class="accent">Cito</span>Store</h1>
    <p class="unit">{name}</p>
    <div class="cards">
      <a class="card" href="/export">
        <h2>Copy files to USB &rarr;</h2>
        <p>Plug a USB drive into the unit and copy images onto it. Sign in with the
           password you use for the shared folders.</p>
      </a>
      <a class="card" href="/protected">
        <h2>Keep folders &rarr;</h2>
        <p>Choose folders that must never be deleted when the disk fills up. Same
           password as copying to USB.</p>
      </a>
      <a class="card" href="/admin">
        <h2>Settings &rarr;</h2>
        <p>Configuration, status and maintenance. Needs the administrator password.</p>
      </a>
    </div>
  </div>
</body>
</html>"""

    def render_export_login(self, error: bool = False, target: str = "/export") -> str:
        msg = (
            "<p class='error'>Wrong password.</p>"
            if error
            else "<p class='hint'>Use the same password you use for the shared folders.</p>"
        )
        return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>USB export - Sign in</title>
  <style>
    body {{ font-family: sans-serif; max-width: 420px; margin: 80px auto; }}
    .error {{ color: #b00020; }}
    .hint {{ color: #666; font-size: 14px; }}
    input, button {{ font-size: 15px; padding: 6px 10px; }}
  </style>
</head>
<body>
  <h1>USB export</h1>
  {msg}
  <form method="post" action="{target}">
    <label>Password</label><br>
    <input type="password" name="password" autofocus autocomplete="current-password"><br><br>
    <button type="submit">Sign in</button>
  </form>
</body>
</html>"""

    def render_login(self, error: str = "") -> str:
        msg = f"<p class='error'>{error}</p>" if error else ""
        return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Vision Web UI - Login</title>
  <style>
    body {{ font-family: sans-serif; max-width: 420px; margin: 80px auto; }}
    .error {{ color: #b00020; }}
  </style>
</head>
<body>
  <h1>Vision Web UI</h1>
  {msg}
  <form method="post">
    <label>Password</label><br>
    <input type="password" name="password" autofocus><br><br>
    <button type="submit">Login</button>
  </form>
</body>
</html>
"""

    def render_setup(self, error: str = "") -> str:
        msg = f"<p class='error'>{error}</p>" if error else ""
        return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Vision Web UI - Setup</title>
  <style>
    body {{ font-family: sans-serif; max-width: 420px; margin: 80px auto; }}
    .error {{ color: #b00020; }}
  </style>
</head>
<body>
  <h1>Set Web UI Password</h1>
  {msg}
  <form method="post">
    <label>New password</label><br>
    <input type="password" name="password"><br><br>
    <label>Confirm password</label><br>
    <input type="password" name="confirm"><br><br>
    <button type="submit">Set password</button>
  </form>
</body>
</html>
"""


def sd_notify(msg: str) -> None:
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.sendto(msg.encode(), addr)
        sock.close()
    except OSError:
        pass


def _watchdog_thread(interval: float) -> None:
    while True:
        sd_notify("WATCHDOG=1")
        time.sleep(interval)


# Threaded server: a request per thread. Single-threaded, every page froze for
# as long as any request took — a resize or wipe (up to an hour), an apply,
# an update upload — and one idle connection (a browser's speculative
# preconnect, or anyone on the LAN) held them all. Changes still run one at a
# time (POST_LOCK, plus require_lock around the system-changing ones); only
# reads run alongside them.
POST_LOCK = threading.Lock()


class DualStackHTTPServer(ThreadingHTTPServer):
    """Serve on both IPv4 and IPv6.

    Binding an IPv6 wildcard socket with IPV6_V6ONLY disabled also accepts IPv4
    (as v4-mapped addresses), so the WebUI is reachable both over ordinary IPv4
    and by an mDNS name that resolves to an IPv6 link-local (fe80::) address on a
    direct, router-free 1-1 link.
    """

    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except (AttributeError, OSError):
            pass
        ThreadingHTTPServer.server_bind(self)


def main():
    cfg = parse_config(load_config_text())
    host = cfg.get("WEBUI_BIND", "0.0.0.0")
    port = int(cfg.get("WEBUI_PORT", "80"))
    # "0.0.0.0"/"::"/"" all mean "all interfaces": use a dual-stack socket so the
    # UI answers on IPv6 too (needed for fe80:: mDNS names on a direct link). A
    # specific literal address is bound as-is.
    if host in ("", "0.0.0.0", "::"):
        server = DualStackHTTPServer(("::", port), WebHandler)
    else:
        server = ThreadingHTTPServer((host, port), WebHandler)
    log(f"webui started on {host}:{port}")
    sd_notify("READY=1")
    watchdog_usec = os.environ.get("WATCHDOG_USEC")
    if watchdog_usec:
        interval = int(watchdog_usec) / 1_000_000 / 2
        t = threading.Thread(target=_watchdog_thread, args=(interval,), daemon=True)
        t.start()
    server.serve_forever()


if __name__ == "__main__":
    main()

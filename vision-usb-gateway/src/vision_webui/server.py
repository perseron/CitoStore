#!/usr/bin/env python3
import base64
import contextlib
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import socket
import subprocess
import threading
import time
from contextlib import contextmanager
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
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


def get_gateway_home() -> str:
    cfg = parse_config(load_config_text())
    return cfg.get("GATEWAY_HOME", "/opt/vision-usb-gateway")


def log(msg: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(f"[{timestamp}] {msg}\n")


def run_cmd(args, input_text=None, timeout=120):
    result = subprocess.run(
        args,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
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


def get_protected_paths() -> list:
    try:
        data = json.loads(PROTECTED_FILE.read_text(encoding="utf-8"))
        return [str(p) for p in data.get("paths", [])]
    except (OSError, ValueError):
        return []


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
    tmp = PROTECTED_FILE.with_suffix(".tmp")
    code, out, err = run_privileged(["/usr/bin/tee", str(tmp)], input_text=payload)
    if code != 0:
        return code, out, err
    return run_privileged(["/bin/mv", "-f", str(tmp), str(PROTECTED_FILE)])


def get_protected_status() -> dict:
    paths = get_protected_paths()
    total = 0
    for rel in paths:
        try:
            target = resolve_export_path("mirror", rel)
        except (ValueError, OSError):
            continue
        code, out, _ = run_cmd(["/usr/bin/du", "-sb", str(target)])
        if code == 0 and out:
            with contextlib.suppress(ValueError):
                total += int(out.split()[0])
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


def start_usb_copy(sources: list, dest_rel: str) -> tuple:
    """Copy into the USB drive in the background, as a transient unit.

    rsync runs under PID 1 rather than in this request: a copy takes minutes to
    hours, and vision-webui is sandboxed (ProtectSystem=strict) so a child of it
    could not write the mount anyway. --no-block returns immediately; progress is
    read back from the unit's journal.
    """
    if usb_copy_running():
        return 1, "", "a copy is already running"
    dest = resolve_export_path("usb", dest_rel)
    if not dest.is_dir():
        return 1, "", "destination is not a directory on the USB drive"

    srcs = []
    for item in sources:
        path = resolve_export_path(item.get("root", "mirror"), item.get("path", ""))
        if not path.exists():
            return 1, "", f"source not found: {item.get('path')}"
        # A trailing slash would copy a directory's *contents*; keep the folder.
        srcs.append(str(path))
    if not srcs:
        return 1, "", "nothing selected"

    # systemd truncates the progress file when rsync opens it, but --no-block
    # returns before that happens: the page polls in between and reads the *last*
    # copy's final line, flashing 100% before the new one has moved a byte.
    run_privileged(["/bin/rm", "-f", USB_PROGRESS_FILE])

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
        "/usr/bin/rsync",
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
        code, out, _ = run_cmd(
            ["/bin/systemctl", "show", f"{USB_JOB_UNIT}.service", "-p", "Result", "--value"]
        )
        result["result"] = out.strip() or "unknown"
    return result


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


def ensure_secret() -> bytes:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if SECRET_FILE.exists():
        return SECRET_FILE.read_bytes()
    secret = secrets.token_bytes(32)
    SECRET_FILE.write_bytes(secret)
    os.chmod(SECRET_FILE, 0o600)
    return secret


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
    PASS_FILE.write_text(json.dumps(data), encoding="utf-8")
    os.chmod(PASS_FILE, 0o600)


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
    code, _, _ = run_cmd(
        ["/usr/bin/smbclient", "-L", "localhost", "-U", f"{user}%{password}"],
        timeout=20,
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
                return {"error": payload.get("error", "nvme smart unavailable")}
            smart = payload.get("smart", {})
            device = payload.get("device", "")
            temp = smart.get("temperature")
            temp_c = None
            if isinstance(temp, (int, float)) and temp >= 200:
                temp_c = round(temp - 273.15, 1)
            elif isinstance(temp, (int, float)):
                temp_c = temp
            return {
                "device": device,
                "temperature_c": temp_c,
                "percentage_used": smart.get("percentage_used"),
                "data_units_read": smart.get("data_units_read"),
                "data_units_written": smart.get("data_units_written"),
                "data_units_written_tb": units_to_tb(smart.get("data_units_written")),
                "power_on_hours": smart.get("power_on_hours"),
                "unsafe_shutdowns": smart.get("unsafe_shutdowns"),
                "media_errors": smart.get("media_errors"),
            }
    return {"error": "nvme smart cache not available"}


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


def apply_network_config(
    iface: str, method: str, address: str, prefix: str, gateway: str, dns: str
):
    conn = get_nm_active_connection(iface)
    if not conn:
        return 1, "", "no active connection for interface"
    if method == "auto":
        args = [
            "nmcli",
            "connection",
            "modify",
            conn,
            "ipv4.method",
            "auto",
            "ipv4.addresses",
            "",
            "ipv4.gateway",
            "",
            "ipv4.dns",
            "",
        ]
        code, out, err = run_cmd(args)
        if code != 0:
            return code, out, err
        return run_cmd(["nmcli", "connection", "up", conn])
    try:
        ipaddress.ip_address(address)
        prefix_int = int(prefix)
        if prefix_int < 1 or prefix_int > 32:
            raise ValueError("prefix out of range")
        if gateway:
            ipaddress.ip_address(gateway)
    except Exception as exc:
        return 1, "", f"invalid network parameters: {exc}"
    addr = f"{address}/{prefix_int}"
    args = [
        "nmcli",
        "connection",
        "modify",
        conn,
        "ipv4.method",
        "manual",
        "ipv4.addresses",
        addr,
        "ipv4.gateway",
        gateway,
        "ipv4.dns",
        dns,
    ]
    code, out, err = run_cmd(args)
    if code != 0:
        return code, out, err
    return run_cmd(["nmcli", "connection", "up", conn])


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
        size = updates["USB_LV_SIZE"]
        if not size or not size[:-1].isdigit() or size[-1] not in "KMGTkmgt":
            return False, "USB_LV_SIZE must look like 100G"
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


def setup_allowed() -> bool:
    """First-run setup is only reachable until a password exists."""
    return not PASS_FILE.exists()


LOGIN_RATE_LIMIT = 5  # max attempts per window
LOGIN_RATE_WINDOW = 900  # 15 minutes
_login_attempts: dict[str, list[float]] = {}


class WebHandler(BaseHTTPRequestHandler):
    server_version = "VisionWebUI/1.0"

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

    def send_json(self, obj: dict, status=200):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location: str):
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", location)
        self.end_headers()

    def is_authenticated(self) -> bool:
        token = get_cookie(self.headers, "session")
        if not token:
            return False
        return validate_session(token)

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
        token = get_cookie(self.headers, "export_session")
        if session_user(token) == EXPORT_SESSION_USER:
            header = self.headers.get("X-CSRF", "")
            return bool(header) and hmac.compare_digest(header, make_csrf(token))
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
            health = STATE_DIR / "health.json"
            fallback = Path("/run/vision-health.json")
            if health.exists():
                try:
                    return self.send_json(json.loads(health.read_text(encoding="utf-8")))
                except json.JSONDecodeError:
                    log("health.json parse error")
                    return self.send_json({
                        "status": "unknown",
                        "issues": ["invalid health.json"],
                        "ts": "",
                    })
            if fallback.exists():
                try:
                    return self.send_json(json.loads(fallback.read_text(encoding="utf-8")))
                except json.JSONDecodeError:
                    log("vision-health.json parse error")
                    return self.send_json({
                        "status": "unknown",
                        "issues": ["invalid vision-health.json"],
                        "ts": "",
                    })
            return self.send_json({"status": "unknown", "issues": [], "ts": ""})
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
            cfg = parse_config(load_config_text())
            iface = cfg.get("SMB_BIND_INTERFACE", "eth0")
            return self.send_json(get_network_config(iface))
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
        content_length = int(self.headers.get("Content-Length", 0))
        if self.path == "/api/update":
            max_size = MAX_UPDATE_SIZE
        elif self.path == "/api/config/bundle/plan":
            max_size = MAX_BUNDLE_SIZE
        else:
            max_size = MAX_BODY_SIZE
        if content_length > max_size:
            self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Request body too large")
            return
        if setup_allowed() and self.path not in ("/setup", "/setup/"):
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
            return self.handle_setup()
        if self.path == "/api/protected":
            if not self.is_export_authenticated():
                return self.send_error(HTTPStatus.UNAUTHORIZED, "Unauthorized")
            if not self.require_export_csrf():
                return self.send_error(HTTPStatus.FORBIDDEN, "CSRF validation failed")
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
        if self.path == "/api/maintenance/rebalance":
            return self.handle_maintenance(["rebalance"])
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
        new_text = update_config_file(base_text, updates)
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        SHADOW_CONF.write_text(new_text, encoding="utf-8")
        last_good = STATE_DIR / "vision-gw.conf.last-good"
        last_good.write_text(new_text, encoding="utf-8")
        log(f"config updated: {', '.join(sorted(updates.keys()))}")
        return self.send_json({"ok": True})

    def handle_apply(self):
        with require_lock():
            gh = get_gateway_home()
            code, out, err = run_privileged([f"{gh}/scripts/apply-shadow-config.sh"])
            log(f"apply-config rc={code} out={out} err={err}")
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=500)
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
        return self.send_json({"ok": True})

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
        run_privileged(["/usr/bin/smbpasswd", "-e", smb_user])
        # Mirror FTP (eth0) authenticates as this same Unix account via PAM, so
        # the SMB password is the one password for both protocols.
        run_privileged(["/usr/sbin/chpasswd"], input_text=f"{smb_user}:{password}\n")
        log(f"smb password changed for {smb_user}")
        return self.send_json({"ok": True})

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
        creds = STATE_DIR / "ftp.creds"
        creds.write_text(f"password={password}\n", encoding="utf-8")
        os.chmod(creds, 0o600)
        # Apply now if the ingest user already exists.
        run_privileged(["/usr/sbin/chpasswd"], input_text=f"{ftp_user}:{password}\n")
        log(f"ftp password changed for {ftp_user}")
        return self.send_json({"ok": True})

    def handle_network(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        iface = data.get("interface", "eth0")
        method = data.get("method", "auto")
        address = data.get("address", "")
        prefix = data.get("prefix", "24")
        gateway = data.get("gateway", "")
        dns = data.get("dns", "")
        with require_lock():
            code, out, err = apply_network_config(iface, method, address, prefix, gateway, dns)
            log(f"network update iface={iface} rc={code} out={out} err={err}")
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=500)
            NETWORK_STATE.write_text(
                json.dumps(
                    {
                        "interface": iface,
                        "method": method,
                        "address": address,
                        "prefix": prefix,
                        "gateway": gateway,
                        "dns": dns,
                    }
                ),
                encoding="utf-8",
            )
            os.chmod(NETWORK_STATE, 0o600)
            return self.send_json({"ok": True})

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
        NAS_CREDS_SHADOW.write_text(render_nas_creds(creds), encoding="utf-8")
        os.chmod(NAS_CREDS_SHADOW, 0o600)
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
            run_privileged([f"{gh}/scripts/rtc-sync.sh", "--systohc"])
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
        if not verify_smb_password(password):
            log("export login rejected")
            return self.send_text(
                self.render_export_login(error=True, target=target), status=401
            )
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
            f"csrf={make_csrf(token)}; SameSite=Strict; Path=/; Max-Age={SESSION_TTL_SEC}",
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
            if not parent.is_dir():
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
            elif action == ["rebalance"]:
                args = [f"{gh}/scripts/rebalance-storage.sh", "--i-know-what-im-doing"]
            elif action == ["resize"]:
                size = data.get("size", "")
                if not size:
                    return self.send_json({"ok": False, "error": "size is required"}, status=400)
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
            privileged = action and action[0] in ("rebalance", "resize", "restore-defaults")
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
        staging = STATE_DIR / "update-staging"
        if staging.exists():
            import shutil

            shutil.rmtree(staging)
        staging.mkdir(parents=True, exist_ok=True)
        archive = staging / "update.tar.gz"
        archive.write_bytes(body)
        code, out, err = run_cmd(["tar", "xzf", str(archive), "-C", str(staging)])
        if code != 0:
            archive.unlink(missing_ok=True)
            return self.send_json({"ok": False, "error": f"extraction failed: {err}"}, status=400)
        manifest = staging / "manifest.json"
        if not manifest.exists():
            return self.send_json({"ok": False, "error": "missing manifest.json"}, status=400)
        install_sh = staging / "install.sh"
        if not install_sh.exists():
            return self.send_json({"ok": False, "error": "missing install.sh"}, status=400)
        try:
            meta = json.loads(manifest.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return self.send_json({"ok": False, "error": "invalid manifest.json"}, status=400)
        version = meta.get("version", "unknown")
        code, _, err = run_cmd(["/bin/systemctl", "start", "vision-update.service"])
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
        parsed = parse_config_text(config_text)
        if not parsed:
            msg = "no valid config entries found"
            return self.send_json({"ok": False, "error": msg}, status=400)
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        SHADOW_CONF.write_text(config_text, encoding="utf-8")
        last_good = STATE_DIR / "vision-gw.conf.last-good"
        last_good.write_text(config_text, encoding="utf-8")
        log(f"config imported ({len(parsed)} keys)")
        return self.send_json({"ok": True})

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
                "message": "Provisioning started. The NVMe is being wiped and "
                "reconfigured; the WebUI will restart in ~1 minute.",
            }
        )

    def handle_maintenance_mode(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        enabled = data.get("enabled", False)
        timers = ["vision-sync.timer", "vision-monitor.timer", "vision-rotator.timer"]
        with require_lock():
            if enabled:
                MAINT_MODE_FLAG.write_text("1", encoding="utf-8")
                for t in timers:
                    run_cmd(["/bin/systemctl", "stop", t])
                log("maintenance mode enabled")
            else:
                MAINT_MODE_FLAG.unlink(missing_ok=True)
                for t in timers:
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
        name = cfg.get("NETBIOS_NAME", "CitoStore")
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


class DualStackHTTPServer(HTTPServer):
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
        HTTPServer.server_bind(self)


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
        server = HTTPServer((host, port), WebHandler)
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

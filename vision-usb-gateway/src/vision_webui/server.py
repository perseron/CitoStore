#!/usr/bin/env python3
import base64
import fcntl
import hashlib
import hmac
import ipaddress
import json
import os
import secrets
import subprocess
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

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

ALLOWED_CONFIG_KEYS = {
    "NETBIOS_NAME",
    "SMB_WORKGROUP",
    "SMB_BIND_INTERFACE",
    "SYNC_INTERVAL_SEC",
    "SYNC_ONBOOT_SEC",
    "SYNC_ONACTIVE_SEC",
    "NAS_ENABLED",
    "NAS_REMOTE",
    "NAS_MOUNT",
    "WEBUI_BIND",
    "WEBUI_PORT",
    "USB_LV_SIZE",
    "BYDATE_USE_FILE_TIME",
    "RAW_APPEND_ALWAYS",
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
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def load_config_text() -> str:
    if SHADOW_CONF.exists():
        return SHADOW_CONF.read_text(encoding="utf-8")
    if DEFAULT_CONF.exists():
        return DEFAULT_CONF.read_text(encoding="utf-8")
    return ""


def parse_config(text: str) -> dict:
    cfg = {}
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        key, value = s.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"')
        cfg[key] = value
    return cfg


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


def format_value(value: str) -> str:
    if value == "":
        return '""'
    if any(c.isspace() for c in value) or '"' in value or "#" in value:
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


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
    token = base64.urlsafe_b64encode(f"{payload}|{sig}".encode("utf-8")).decode("ascii")
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
        if int(expiry) < int(time.time()):
            return False
        return True
    except Exception:
        return False


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


def require_lock():
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    f = LOCK_FILE.open("w")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


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
            with open("/proc/uptime", "r", encoding="utf-8") as f:
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
        ["lvs", "-a", "--noheadings", "--units", "g", "--nosuffix", "-o", "lv_path,lv_size,data_percent"]
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


def apply_network_config(iface: str, method: str, address: str, prefix: str, gateway: str, dns: str):
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
    for key in ("SYNC_INTERVAL_SEC", "SYNC_ONBOOT_SEC", "SYNC_ONACTIVE_SEC"):
        if key in updates:
            val = updates[key]
            if not val or not all(c.isalnum() for c in val):
                return False, f"{key} must be a systemd time string like 30s or 2min"
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
    if "NAS_ENABLED" in updates:
        if updates["NAS_ENABLED"] not in ("true", "false"):
            return False, "NAS_ENABLED must be true or false"
    for key in ("BYDATE_USE_FILE_TIME", "RAW_APPEND_ALWAYS"):
        if key in updates and updates[key] not in ("true", "false"):
            return False, f"{key} must be true or false"
    return True, ""


class WebHandler(BaseHTTPRequestHandler):
    server_version = "VisionWebUI/1.0"

    def send_text(self, text: str, status=200, content_type="text/html; charset=utf-8"):
        data = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, obj: dict, status=200):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
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

    def require_csrf(self) -> bool:
        csrf_cookie = get_cookie(self.headers, "csrf")
        if not csrf_cookie:
            return False
        token = get_cookie(self.headers, "session")
        if not token:
            return False
        expected = make_csrf(token)
        header = self.headers.get("X-CSRF", "")
        if header and hmac.compare_digest(header, csrf_cookie) and hmac.compare_digest(
            header, expected
        ):
            return True
        return False

    def do_GET(self):
        if PASS_FILE.exists() is False and self.path not in ("/setup", "/setup/"):
            return self.redirect("/setup")
        if self.path in ("/login", "/login/"):
            return self.send_text(self.render_login())
        if self.path in ("/setup", "/setup/"):
            return self.send_text(self.render_setup())
        if self.path.startswith("/static/"):
            return self.serve_static(self.path[len("/static/") :])
        if not self.is_authenticated():
            return self.redirect("/login")
        if self.path in ("/", "/index.html"):
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
                "mirror_usage": get_disk_usage("/srv/vision_mirror"),
                "nvme": get_nvme_smart(),
            }
            return self.send_json(data)
        if self.path.startswith("/api/health"):
            health = STATE_DIR / "health.json"
            fallback = Path("/run/vision-health.json")
            if health.exists():
                return self.send_json(json.loads(health.read_text(encoding="utf-8")))
            if fallback.exists():
                return self.send_json(json.loads(fallback.read_text(encoding="utf-8")))
            return self.send_json({"status": "unknown", "issues": [], "ts": ""})
        if self.path.startswith("/api/config"):
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
            return self.send_json({"ok": True})
        if self.path.startswith("/api/time"):
            code, out, err = run_cmd(["/usr/bin/timedatectl", "status"])
            if code != 0:
                return self.send_json({"status": err or "failed to read time"}, status=500)
            return self.send_json({"status": out})
        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_POST(self):
        if PASS_FILE.exists() is False and self.path not in ("/setup", "/setup/"):
            return self.redirect("/setup")
        if self.path in ("/login", "/login/"):
            return self.handle_login()
        if self.path in ("/setup", "/setup/"):
            return self.handle_setup()
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
        if self.path == "/api/maintenance/wipe":
            return self.handle_maintenance(["wipe"])
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
        if self.path == "/api/network":
            return self.handle_network()
        if self.path == "/api/time":
            return self.handle_time()
        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def handle_login(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        params = parse_qs(body)
        password = params.get("password", [""])[0]
        if verify_password(password):
            token = make_session("admin")
            csrf = make_csrf(token)
            self.send_response(HTTPStatus.SEE_OTHER)
            self.send_header("Set-Cookie", f"session={token}; HttpOnly; Path=/")
            self.send_header("Set-Cookie", f"csrf={csrf}; Path=/")
            self.send_header("Location", "/")
            self.end_headers()
            log("login success")
        else:
            log("login failed")
            self.send_text(self.render_login("Invalid password"), status=401)

    def handle_setup(self):
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
        lock = require_lock()
        try:
            gh = get_gateway_home()
            code, out, err = run_cmd([f"{gh}/scripts/apply-shadow-config.sh"])
            log(f"apply-config rc={code} out={out} err={err}")
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=500)
            return self.send_json({"ok": True})
        finally:
            lock.close()

    def handle_webui_password(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        password = data.get("password", "")
        confirm = data.get("confirm", "")
        if not password or password != confirm:
            return self.send_json({"ok": False, "error": "passwords do not match"}, status=400)
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
        cfg = parse_config(load_config_text())
        smb_user = cfg.get("SMB_USER", "smbuser")
        input_text = f"{password}\n{password}\n"
        code, out, err = run_cmd(["/usr/bin/smbpasswd", "-s", "-a", smb_user], input_text=input_text)
        if code != 0:
            return self.send_json({"ok": False, "error": err or out}, status=500)
        run_cmd(["/usr/bin/smbpasswd", "-e", smb_user])
        log(f"smb password changed for {smb_user}")
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
        lock = require_lock()
        try:
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
        finally:
            lock.close()

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
        lock = require_lock()
        try:
            code, out, err = run_cmd(["/usr/bin/timedatectl", "set-time", value])
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=500)
            gh = get_gateway_home()
            run_cmd([f"{gh}/scripts/rtc-sync.sh", "--systohc"])
            log(f"system time set: {value}")
            return self.send_json({"ok": True})
        finally:
            lock.close()

    def handle_maintenance(self, action):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        data = json.loads(body or "{}")
        lock = require_lock()
        try:
            gh = get_gateway_home()
            if action == ["wipe"]:
                args = ["/bin/systemctl", "start", "vision-wipe.service"]
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
            else:
                return self.send_json({"ok": False, "error": "unknown action"}, status=400)
            code, out, err = run_cmd(args, timeout=3600)
            log(f"maintenance {action} rc={code} out={out} err={err}")
            if code != 0:
                return self.send_json({"ok": False, "error": err or out}, status=500)
            return self.send_json({"ok": True})
        finally:
            lock.close()

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


def main():
    cfg = parse_config(load_config_text())
    host = cfg.get("WEBUI_BIND", "0.0.0.0")
    port = int(cfg.get("WEBUI_PORT", "80"))
    server = HTTPServer((host, port), WebHandler)
    log(f"webui started on {host}:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()

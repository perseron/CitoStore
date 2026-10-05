#!/usr/bin/env bash
set -euo pipefail

# Read the NVMe's SMART log (every 10 min, vision-nvme-health.timer), judge it
# and cache the result:
#   /run/vision-nvme.json (+ .state/nvme.json): raw log + verdict, for the WebUI
#   /run/vision-nvme.issues: "<warn|error>|<message>" lines, for vision-monitor,
#     which puts them into the health banner (nvme_health_issues, common.sh)
# Before, nothing judged the log: the drive's own failure flags
# (critical_warning, spare below threshold) were not even read, the wear level
# was looked up under a key nvme-cli does not use (percentage_used, the JSON says
# percent_used), and the only verdict was in the WebUI's status text — never in
# the health.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

STATE_DIR=${NVME_STATE_DIR:-/srv/vision_mirror/.state}
RUN_OUT=${NVME_RUN_OUT:-/run/vision-nvme.json}
ISSUES_OUT=${NVME_ISSUES_OUT:-/run/vision-nvme.issues}
STATE_OUT=$STATE_DIR/nvme.json
NVME=${NVME_CLI:-/usr/sbin/nvme}

require_root

timestamp=$(date -Iseconds)

# <json> -> both caches; the issues file from it.
publish() {
  printf '%s\n' "$1" > "$RUN_OUT.tmp" && mv -f "$RUN_OUT.tmp" "$RUN_OUT"
  # The NVMe copy only while the mirror is mounted (never into the bare mount
  # point; the old mkdir -p did).
  if [[ -d "$STATE_DIR" ]] && { [[ -n "${NVME_STATE_DIR:-}" ]] || mountpoint -q "$(dirname "$STATE_DIR")"; }; then
    { printf '%s\n' "$1" > "$STATE_OUT.tmp" && mv -f "$STATE_OUT.tmp" "$STATE_OUT"; } 2>/dev/null || true
  fi
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for level, msg in d.get("issues", []):
    print(f"{level}|{msg}")
' > "$ISSUES_OUT.tmp" && mv -f "$ISSUES_OUT.tmp" "$ISSUES_OUT"
}

fail() {  # <message> [device]: no SMART at all — the NVMe holds every image
  publish "$(python3 -c '
import json, sys
msg, dev, ts = sys.argv[1:4]
print(json.dumps({"status": "error", "device": dev, "error": msg, "ts": ts,
                  "health": "error", "issues": [["error", f"NVMe: {msg}"]]}))
' "$1" "${2:-}" "$timestamp")"
  exit 0
}

list_out=$("$NVME" list -o json 2>/dev/null || true)
[[ -n "$list_out" ]] || fail "nvme list returned no data"

# python3 -c keeps the pipe as stdin — a `python3 - <<heredoc` would REPLACE
# stdin with the heredoc, so the JSON never reached python and the unread pipe
# intermittently killed the script with EPIPE under set -e.
device=$(printf '%s' "$list_out" | python3 -c '
import json,sys
raw=sys.stdin.read()
start=raw.find("{")
end=raw.rfind("}")
if start == -1 or end == -1 or end <= start:
    raise SystemExit(0)
snippet=raw[start:end+1]
try:
    data=json.loads(snippet)
except json.JSONDecodeError:
    raise SystemExit(0)
devices=data.get("Devices", [])
print(devices[0].get("DevicePath", "") if devices else "")
' || true)

if [[ -z "$device" ]]; then
  text_list=$("$NVME" list 2>/dev/null || true)
  device=$(printf '%s\n' "$text_list" | awk '/^\/dev\/nvme/ {print $1; exit}')
  [[ -n "$device" ]] || fail "no NVMe device found"
fi

smart=$("$NVME" smart-log -o json "$device" 2>/dev/null) || fail "SMART log could not be read" "$device"
# The drive's own temperature thresholds (Kelvin); optional.
ctrl=$("$NVME" id-ctrl -o json "$device" 2>/dev/null || echo '{}')

publish "$(python3 -c '
import json, sys
device, ts, smart_raw, ctrl_raw = sys.argv[1:5]
smart = json.loads(smart_raw)
try:
    ctrl = json.loads(ctrl_raw)
except ValueError:
    ctrl = {}

def num(key):
    """nvme-cli prints big counters as "2,752,848" strings."""
    v = smart.get(key)
    if isinstance(v, str):
        v = v.replace(",", "").strip()
    try:
        return int(v)
    except (TypeError, ValueError):
        return None

def kelvin_c(v):
    return round(v - 273.15) if isinstance(v, (int, float)) and v > 200 else None

issues = []
cw = smart.get("critical_warning")
if isinstance(cw, dict):  # newer nvme-cli: decoded flags
    cw = cw.get("value")
cw = cw if isinstance(cw, int) else 0
# Critical warning bits (NVMe base spec, SMART / Health Information log).
flags = [
    (0x01, "error", "available spare below the threshold"),
    (0x02, "warn", "temperature outside its limits"),
    (0x04, "error", "reliability degraded (media or internal errors)"),
    (0x08, "error", "media placed in READ-ONLY mode"),
    (0x10, "error", "volatile memory backup failed"),
    (0x20, "error", "persistent memory region read-only"),
]
for bit, level, text in flags:
    if cw & bit:
        issues.append([level, f"NVMe reports: {text} - replace the SSD" if level == "error" else f"NVMe reports: {text}"])

spare, spare_min = num("avail_spare"), num("spare_thresh")
if spare is not None and spare_min is not None and spare_min > 0 and spare <= spare_min and not cw & 0x01:
    issues.append(["error", f"NVMe spare blocks used up ({spare}% left, minimum {spare_min}%) - replace the SSD"])

used = num("percent_used")
if used is None:
    used = num("percentage_used")
if used is not None and used >= 100:
    issues.append(["warn", f"NVMe rated write endurance used up ({used}%) - plan to replace the SSD"])
elif used is not None and used >= 90:
    issues.append(["warn", f"NVMe wear {used}% of its rated write endurance - plan to replace the SSD"])

media = num("media_errors")
if media:
    issues.append(["warn", f"NVMe has {media} unrecovered media error(s) - data was unreadable; plan to replace the SSD"])

temp_c = kelvin_c(smart.get("temperature"))
warn_c, crit_c = kelvin_c(ctrl.get("wctemp")) or 70, kelvin_c(ctrl.get("cctemp")) or 80
if temp_c is not None and temp_c >= crit_c:
    issues.append(["error", f"NVMe at {temp_c} C, above its critical limit ({crit_c} C) - check cooling"])
elif temp_c is not None and temp_c >= warn_c and not cw & 0x02:
    issues.append(["warn", f"NVMe at {temp_c} C, above its warning limit ({warn_c} C) - check cooling"])

health = "error" if any(l == "error" for l, _ in issues) else "warn" if issues else "ok"
print(json.dumps({"status": "ok", "device": device, "ts": ts, "health": health, "issues": issues,
                  "limits": {"warn_c": warn_c, "crit_c": crit_c}, "smart": smart}))
' "$device" "$timestamp" "$smart" "$ctrl")"

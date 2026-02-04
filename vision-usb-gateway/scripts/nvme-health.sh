#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

STATE_DIR=/srv/vision_mirror/.state
RUN_OUT=/run/vision-nvme.json
STATE_OUT=$STATE_DIR/nvme.json

require_root

mkdir -p "$STATE_DIR"

timestamp=$(date -Iseconds)

list_out=$(/usr/sbin/nvme list -o json 2>/dev/null || true)
if [[ -z "$list_out" ]]; then
  printf '{"status":"error","error":"nvme list returned no data","ts":"%s"}\n' "$timestamp" | tee "$RUN_OUT" "$STATE_OUT" >/dev/null
  exit 0
fi

device=$(printf '%s' "$list_out" | python3 - <<'PY'
import json,sys
raw=sys.stdin.read()
start=raw.find("{")
end=raw.rfind("}")
if start == -1 or end == -1 or end <= start:
    print("")
    sys.exit(0)
snippet=raw[start:end+1]
try:
    data=json.loads(snippet)
except json.JSONDecodeError:
    print("")
    sys.exit(0)
devices=data.get("Devices", [])
print(devices[0].get("DevicePath", "") if devices else "")
PY
)

if [[ -z "$device" ]]; then
  printf '{"status":"error","error":"no NVMe devices found or invalid nvme list JSON","ts":"%s"}\n' "$timestamp" | tee "$RUN_OUT" "$STATE_OUT" >/dev/null
  exit 0
fi

if ! out=$(/usr/sbin/nvme smart-log -o json "$device" 2>/dev/null); then
  printf '{"status":"error","device":"%s","error":"smart log failed","ts":"%s"}\n' "$device" "$timestamp" | tee "$RUN_OUT" "$STATE_OUT" >/dev/null
  exit 0
fi

printf '{"status":"ok","device":"%s","ts":"%s","smart":%s}\n' "$device" "$timestamp" "$out" | tee "$RUN_OUT" "$STATE_OUT" >/dev/null

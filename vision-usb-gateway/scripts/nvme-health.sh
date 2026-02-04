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

device=$(/usr/sbin/nvme list -o json | python3 - <<'PY'
import json,sys
data=json.load(sys.stdin)
devices=data.get("Devices", [])
print(devices[0]["DevicePath"] if devices else "")
PY
)

timestamp=$(date -Iseconds)
if [[ -z "$device" ]]; then
  printf '{"status":"error","error":"no NVMe devices found","ts":"%s"}\n' "$timestamp" | tee "$RUN_OUT" "$STATE_OUT" >/dev/null
  exit 0
fi

if ! out=$(/usr/sbin/nvme smart-log -o json "$device" 2>/dev/null); then
  printf '{"status":"error","device":"%s","error":"smart log failed","ts":"%s"}\n' "$device" "$timestamp" | tee "$RUN_OUT" "$STATE_OUT" >/dev/null
  exit 0
fi

printf '{"status":"ok","device":"%s","ts":"%s","smart":%s}\n' "$device" "$timestamp" "$out" | tee "$RUN_OUT" "$STATE_OUT" >/dev/null

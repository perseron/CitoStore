#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

require_root
load_config

errors=0

check() {
  local desc="$1" cmd="$2"
  if eval "$cmd"; then
    echo "OK: $desc"
  else
    echo "FAIL: $desc"
    errors=$((errors+1))
  fi
}

check "usb gadget service" "systemctl is-enabled usb-gadget.service >/dev/null 2>&1"
check "vision sync timer" "systemctl is-enabled vision-sync.timer >/dev/null 2>&1"
check "mirror mount" "mountpoint -q ${MIRROR_MOUNT:-/srv/vision_mirror}"
check "samba running" "systemctl is-active smbd >/dev/null 2>&1"

if [[ $errors -ne 0 ]]; then
  exit 1
fi
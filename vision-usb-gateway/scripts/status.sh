#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_config

echo "Active USB: $(cat /run/vision-usb-active 2>/dev/null || echo unknown)"
if [[ -f /run/vision-rotate.state ]]; then
  cat /run/vision-rotate.state
fi

lvs
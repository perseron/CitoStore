#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root

CONFIG_TXT=/boot/firmware/config.txt
CMDLINE=/boot/firmware/cmdline.txt

if ! grep -q "^dtoverlay=dwc2" "$CONFIG_TXT"; then
  log "adding dtoverlay=dwc2,dr_mode=peripheral"
  echo "dtoverlay=dwc2,dr_mode=peripheral" >> "$CONFIG_TXT"
fi

cmdline_add "modules-load=dwc2"

append_if_missing "dwc2" /etc/modules
append_if_missing "libcomposite" /etc/modules

log "OTG configuration applied"
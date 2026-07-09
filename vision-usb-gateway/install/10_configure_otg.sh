#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root

CONFIG_TXT=/boot/firmware/config.txt
CMDLINE=/boot/firmware/cmdline.txt

# The USB gadget requires peripheral mode. Current Raspberry Pi OS ships a
# `dtoverlay=dwc2,dr_mode=host` line in the [cm5] section by default, so we must
# force peripheral rather than just check for any dwc2 overlay being present.
if grep -qE "^dtoverlay=dwc2,dr_mode=peripheral" "$CONFIG_TXT"; then
  log "dwc2 peripheral mode already configured"
elif grep -qE "^dtoverlay=dwc2" "$CONFIG_TXT"; then
  log "forcing existing dwc2 overlay to peripheral mode"
  sed -i "s/^dtoverlay=dwc2.*/dtoverlay=dwc2,dr_mode=peripheral/" "$CONFIG_TXT"
else
  log "adding dtoverlay=dwc2,dr_mode=peripheral"
  echo "dtoverlay=dwc2,dr_mode=peripheral" >> "$CONFIG_TXT"
fi

cmdline_add "modules-load=dwc2"

append_if_missing "dwc2" /etc/modules
append_if_missing "libcomposite" /etc/modules

log "OTG configuration applied"
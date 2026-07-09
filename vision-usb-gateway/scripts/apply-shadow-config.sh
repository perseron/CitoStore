#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

# Snapshot the current shadow config as last-good before applying; health-check
# rolls back to this if the live config later fails its validity check.
if [[ -f "$SHADOW_CONF_DEFAULT" ]]; then
  cp "$SHADOW_CONF_DEFAULT" /srv/vision_mirror/.state/vision-gw.conf.last-good
fi

# update-config.sh restores /etc/vision-gw.conf (+ NAS creds) from the shadow,
# re-asserts GATEWAY_HOME, and writes /etc/vision-gw.env. Everything below reads
# the populated /etc/vision-gw.conf, so it must run first.
"$GATEWAY_HOME/scripts/update-config.sh"
"$GATEWAY_HOME/install/50_configure_samba.sh"

if grep -q '^NAS_ENABLED=true' /etc/vision-gw.conf 2>/dev/null; then
  "$GATEWAY_HOME/install/60_configure_nas_optional.sh"
else
  systemctl disable --now mnt-nas.automount nas-sync.timer || true
fi

# eth1 + FTP/SFTP ingest (overlay-safe: re-applied from config on every boot).
"$GATEWAY_HOME/install/70_configure_ingest.sh" || true

systemctl restart vision-webui.service || true

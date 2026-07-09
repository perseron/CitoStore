#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root

if [[ -f /etc/vision-gw.conf ]]; then
  if grep -q '^NAS_ENABLED=' /etc/vision-gw.conf; then
    sed -i 's/^NAS_ENABLED=.*/NAS_ENABLED=true/' /etc/vision-gw.conf
  else
    echo 'NAS_ENABLED=true' >> /etc/vision-gw.conf
  fi
fi

load_config

if [[ ! -f /etc/vision-nas.creds ]]; then
  cp "$SCRIPT_DIR/../conf/nas/vision-nas.creds.example" /etc/vision-nas.creds
  chmod 0600 /etc/vision-nas.creds
  log "created /etc/vision-nas.creds (edit credentials)"
fi

# Rewrite the full env file (never a NAS-only subset -- that dropped the
# SMB/WebUI/RTC/sync keys other units read).
write_gateway_env

systemctl daemon-reload
systemctl enable mnt-nas.automount nas-sync.timer
systemctl restart mnt-nas.automount

log "NAS automount enabled"
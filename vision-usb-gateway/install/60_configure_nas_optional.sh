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

cat > /etc/vision-gw.env <<EOF
GATEWAY_HOME=${GATEWAY_HOME:-/opt/vision-usb-gateway}
NAS_REMOTE=${NAS_REMOTE:-//nas/vision}
NAS_MOUNT=${NAS_MOUNT:-/mnt/nas}
NAS_CREDENTIALS=${NAS_CREDENTIALS:-/etc/vision-nas.creds}
EOF

systemctl daemon-reload
systemctl enable mnt-nas.automount nas-sync.timer
systemctl restart mnt-nas.automount

log "NAS automount enabled"
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root

GATEWAY_HOME=$(cd "$SCRIPT_DIR/.." && pwd)

if [[ -f /etc/vision-gw.conf ]]; then
  if grep -q '^GATEWAY_HOME=' /etc/vision-gw.conf; then
    sed -i "s#^GATEWAY_HOME=.*#GATEWAY_HOME=$GATEWAY_HOME#" /etc/vision-gw.conf
  else
    echo "GATEWAY_HOME=$GATEWAY_HOME" >> /etc/vision-gw.conf
  fi
fi

load_config

# Write systemd-safe env file (no arrays)
cat > /etc/vision-gw.env <<EOF
GATEWAY_HOME=$GATEWAY_HOME
NAS_REMOTE=${NAS_REMOTE:-//nas/vision}
NAS_MOUNT=${NAS_MOUNT:-/mnt/nas}
NAS_CREDENTIALS=${NAS_CREDENTIALS:-/etc/vision-nas.creds}
SMB_BIND_INTERFACE=${SMB_BIND_INTERFACE:-eth0}
SMB_WORKGROUP=${SMB_WORKGROUP:-WORKGROUP}
NETBIOS_NAME=${NETBIOS_NAME:-CITOSTORE}
EOF

log "installing python package"
python3 -m pip install --break-system-packages -e "$GATEWAY_HOME"

chmod +x "$GATEWAY_HOME/scripts/"*.sh
chmod +x "$GATEWAY_HOME/install/"*.sh

log "installing systemd units"
install -m 0644 "$SCRIPT_DIR/../systemd/"*.service /etc/systemd/system/
install -m 0644 "$SCRIPT_DIR/../systemd/"*.timer /etc/systemd/system/
install -m 0644 "$SCRIPT_DIR/../systemd/"*.mount /etc/systemd/system/
install -m 0644 "$SCRIPT_DIR/../systemd/"*.automount /etc/systemd/system/

safe_mkdir /srv/vision_mirror/.state
chmod 0755 /srv/vision_mirror
chmod 0755 /srv/vision_mirror/.state

systemctl daemon-reload
systemctl enable usb-gadget.service
systemctl enable vision-sync.timer vision-monitor.timer vision-rotator.timer mirror-retention.timer

if [[ "${NAS_ENABLED:-false}" == "true" ]]; then
  systemctl enable mnt-nas.automount nas-sync.timer
fi

log "systemd units installed and enabled"

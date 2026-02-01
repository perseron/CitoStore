#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config

GATEWAY_HOME=${GATEWAY_HOME:-/opt/vision-usb-gateway}

: "${SYNC_ONBOOT_SEC:=2min}"
: "${SYNC_ONACTIVE_SEC:=2min}"
: "${SYNC_INTERVAL_SEC:=2min}"

# Write systemd-safe env file (no arrays).
cat > /etc/vision-gw.env <<EOF
GATEWAY_HOME=$GATEWAY_HOME
NAS_REMOTE=${NAS_REMOTE:-//nas/vision}
NAS_MOUNT=${NAS_MOUNT:-/mnt/nas}
NAS_CREDENTIALS=${NAS_CREDENTIALS:-/etc/vision-nas.creds}
SMB_BIND_INTERFACE=${SMB_BIND_INTERFACE:-eth0}
SMB_WORKGROUP=${SMB_WORKGROUP:-WORKGROUP}
NETBIOS_NAME=${NETBIOS_NAME:-CITOSTORE}
EOF

# Update timer override from config.
SYNC_TIMER_DIR=/etc/systemd/system/vision-sync.timer.d
SYNC_TIMER_OVERRIDE=$SYNC_TIMER_DIR/override.conf
mkdir -p "$SYNC_TIMER_DIR"
cat > "$SYNC_TIMER_OVERRIDE" <<EOF
[Timer]
OnBootSec=$SYNC_ONBOOT_SEC
OnActiveSec=$SYNC_ONACTIVE_SEC
OnUnitActiveSec=$SYNC_INTERVAL_SEC
EOF

systemctl daemon-reload
systemctl restart vision-sync.timer

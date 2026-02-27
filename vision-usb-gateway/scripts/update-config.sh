#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
SHADOW_CONF=/srv/vision_mirror/.state/vision-gw.conf
if [[ -f "$SHADOW_CONF" ]]; then
  cp "$SHADOW_CONF" /etc/vision-gw.conf
fi

SHADOW_CREDS=/srv/vision_mirror/.state/vision-nas.creds
if [[ -f "$SHADOW_CREDS" ]]; then
  cp "$SHADOW_CREDS" /etc/vision-nas.creds
  chmod 0600 /etc/vision-nas.creds
elif [[ -f /etc/vision-nas.creds ]]; then
  cp /etc/vision-nas.creds "$SHADOW_CREDS"
  chmod 0600 "$SHADOW_CREDS"
fi

load_config

GATEWAY_HOME=${GATEWAY_HOME:-/opt/vision-usb-gateway}

: "${SYNC_ONBOOT_SEC:=2min}"
: "${SYNC_ONACTIVE_SEC:=2min}"
: "${SYNC_INTERVAL_SEC:=2min}"
: "${SYNC_HI_INTERVAL_SEC:=10s}"
: "${RTC_SYNC_INTERVAL:=1h}"

# Write systemd-safe env file (no arrays).
cat > /etc/vision-gw.env <<EOF
GATEWAY_HOME=$GATEWAY_HOME
NAS_REMOTE=${NAS_REMOTE:-//nas/vision}
NAS_MOUNT=${NAS_MOUNT:-/mnt/nas}
NAS_CREDENTIALS=${NAS_CREDENTIALS:-/etc/vision-nas.creds}
SMB_BIND_INTERFACE=${SMB_BIND_INTERFACE:-eth0}
SMB_WORKGROUP=${SMB_WORKGROUP:-WORKGROUP}
NETBIOS_NAME=${NETBIOS_NAME:-CITOSTORE}
WEBUI_BIND=${WEBUI_BIND:-0.0.0.0}
WEBUI_PORT=${WEBUI_PORT:-80}
RTC_ENABLED=${RTC_ENABLED:-false}
RTC_DEVICE=${RTC_DEVICE:-/dev/rtc0}
RTC_UTC=${RTC_UTC:-true}
RTC_SYNC_INTERVAL=${RTC_SYNC_INTERVAL:-1h}
SYNC_HI_INTERVAL_SEC=${SYNC_HI_INTERVAL_SEC:-10s}
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

SYNC_FAST_TIMER_DIR=/etc/systemd/system/vision-sync-fast.timer.d
SYNC_FAST_TIMER_OVERRIDE=$SYNC_FAST_TIMER_DIR/override.conf
mkdir -p "$SYNC_FAST_TIMER_DIR"
cat > "$SYNC_FAST_TIMER_OVERRIDE" <<EOF
[Timer]
OnActiveSec=$SYNC_HI_INTERVAL_SEC
OnUnitActiveSec=$SYNC_HI_INTERVAL_SEC
EOF

systemctl daemon-reload
systemctl restart vision-sync.timer
systemctl restart vision-sync-fast.timer >/dev/null 2>&1 || true
systemctl restart vision-rtc-sync.timer || true

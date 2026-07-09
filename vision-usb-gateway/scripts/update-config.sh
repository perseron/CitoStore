#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

# Repopulate the live config + NAS creds from the authoritative NVMe shadow copy.
restore_shadow_conf

SHADOW_CREDS=/srv/vision_mirror/.state/vision-nas.creds
if [[ -f "$SHADOW_CREDS" ]]; then
  cp "$SHADOW_CREDS" /etc/vision-nas.creds
  chmod 0600 /etc/vision-nas.creds
elif [[ -f /etc/vision-nas.creds ]]; then
  cp /etc/vision-nas.creds "$SHADOW_CREDS"
  chmod 0600 "$SHADOW_CREDS"
fi

load_config

: "${SYNC_ONBOOT_SEC:=2min}"
: "${SYNC_ONACTIVE_SEC:=2min}"
: "${SYNC_INTERVAL_SEC:=2min}"
: "${SYNC_HI_INTERVAL_SEC:=10s}"
: "${RTC_SYNC_INTERVAL:=1h}"

write_gateway_env

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

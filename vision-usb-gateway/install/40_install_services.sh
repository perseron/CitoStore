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

# Timer tuning (defaults match unit file)
: "${SYNC_ONBOOT_SEC:=2min}"
: "${SYNC_ONACTIVE_SEC:=2min}"
: "${SYNC_INTERVAL_SEC:=2min}"
: "${RTC_SYNC_INTERVAL:=1h}"

# Write systemd-safe env file (no arrays)
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
if [[ -d "$SCRIPT_DIR/../systemd/smbd.service.d" ]]; then
  mkdir -p /etc/systemd/system/smbd.service.d
  install -m 0644 "$SCRIPT_DIR/../systemd/smbd.service.d/"*.conf /etc/systemd/system/smbd.service.d/
fi
if [[ -d "$SCRIPT_DIR/../systemd/nmbd.service.d" ]]; then
  mkdir -p /etc/systemd/system/nmbd.service.d
  install -m 0644 "$SCRIPT_DIR/../systemd/nmbd.service.d/"*.conf /etc/systemd/system/nmbd.service.d/
fi

log "configuring vision-sync.timer override"
SYNC_TIMER_DIR=/etc/systemd/system/vision-sync.timer.d
SYNC_TIMER_OVERRIDE=$SYNC_TIMER_DIR/override.conf
mkdir -p "$SYNC_TIMER_DIR"
cat > "$SYNC_TIMER_OVERRIDE" <<EOF
[Timer]
OnBootSec=$SYNC_ONBOOT_SEC
OnActiveSec=$SYNC_ONACTIVE_SEC
OnUnitActiveSec=$SYNC_INTERVAL_SEC
EOF

log "configuring vision-rtc-sync.timer override"
RTC_TIMER_DIR=/etc/systemd/system/vision-rtc-sync.timer.d
RTC_TIMER_OVERRIDE=$RTC_TIMER_DIR/override.conf
mkdir -p "$RTC_TIMER_DIR"
cat > "$RTC_TIMER_OVERRIDE" <<EOF
[Timer]
OnBootSec=5min
OnUnitActiveSec=$RTC_SYNC_INTERVAL
EOF

safe_mkdir /srv/vision_mirror/.state
chmod 0755 /srv/vision_mirror
chmod 0755 /srv/vision_mirror/.state

systemctl daemon-reload
systemctl enable vision-gw-health.service
systemctl enable usb-gadget.service
systemctl enable vision-gw-network.service
systemctl enable vision-gw-config.service
systemctl enable vision-sync.timer vision-monitor.timer vision-rotator.timer mirror-retention.timer
systemctl enable vision-webui.service
systemctl enable vision-rtc-boot.service
systemctl enable vision-rtc-sync.timer
systemctl enable vision-snapshot-cleanup.timer

if [[ "${NAS_ENABLED:-false}" == "true" ]]; then
  systemctl enable mnt-nas.automount nas-sync.timer
fi

log "systemd units installed and enabled"

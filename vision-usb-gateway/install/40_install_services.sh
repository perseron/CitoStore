#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root

# GATEWAY_HOME is set by common.sh (derived from its own location). Record it in
# the config so health-check's validity marker is present.
ensure_gateway_home_in_conf

load_config

# Timer tuning (defaults match unit file)
: "${SYNC_ONBOOT_SEC:=2min}"
: "${SYNC_ONACTIVE_SEC:=2min}"
: "${SYNC_INTERVAL_SEC:=2min}"
: "${SYNC_HI_INTERVAL_SEC:=10s}"
: "${RTC_SYNC_INTERVAL:=1h}"

write_gateway_env

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

# Stamp the real repo path into each unit's GATEWAY_HOME fallback. The
# EnvironmentFile overrides this at runtime, but the fallback is what systemd
# uses to expand ${GATEWAY_HOME} in ExecStart if the env file is ever missing,
# so it must point at wherever this repo is actually installed.
grep -rl '^Environment=GATEWAY_HOME=' /etc/systemd/system/ 2>/dev/null | while read -r unit; do
  sed -i "s#^Environment=GATEWAY_HOME=.*#Environment=GATEWAY_HOME=$GATEWAY_HOME#" "$unit"
done
# Must land on the persistent root: vsftpd starts before anything re-applies
# config at boot, so generating this drop-in later would always be too late.
if [[ -d "$SCRIPT_DIR/../systemd/vsftpd.service.d" ]]; then
  mkdir -p /etc/systemd/system/vsftpd.service.d
  install -m 0644 "$SCRIPT_DIR/../systemd/vsftpd.service.d/"*.conf /etc/systemd/system/vsftpd.service.d/
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

log "configuring vision-sync-fast.timer override"
SYNC_FAST_TIMER_DIR=/etc/systemd/system/vision-sync-fast.timer.d
SYNC_FAST_TIMER_OVERRIDE=$SYNC_FAST_TIMER_DIR/override.conf
mkdir -p "$SYNC_FAST_TIMER_DIR"
cat > "$SYNC_FAST_TIMER_OVERRIDE" <<EOF
[Timer]
OnActiveSec=$SYNC_HI_INTERVAL_SEC
OnUnitActiveSec=$SYNC_HI_INTERVAL_SEC
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
systemctl enable vision-sync.timer mirror-retention.timer
systemctl disable vision-sync-fast.timer >/dev/null 2>&1 || true
systemctl stop vision-sync-fast.timer >/dev/null 2>&1 || true
systemctl disable vision-monitor.timer vision-rotator.timer >/dev/null 2>&1 || true
systemctl enable vision-webui.service
systemctl enable vision-shadow-config.service
systemctl enable vision-rtc-boot.service
systemctl enable vision-rtc-sync.timer
systemctl enable vision-snapshot-cleanup.timer
systemctl enable vision-nvme-health.timer
systemctl enable vision-log-cleanup.timer
systemctl enable vision-persist-boot-log.service
systemctl enable vision-update-reapply.service

# vision-firstboot.service is installed but only enabled by
# prepare-golden-image.sh (it must run on clones, not on a normal install).
systemctl disable vision-firstboot.service >/dev/null 2>&1 || true

if [[ "${NAS_ENABLED:-false}" == "true" ]]; then
  systemctl enable mnt-nas.automount nas-sync.timer
fi

log "systemd units installed and enabled"

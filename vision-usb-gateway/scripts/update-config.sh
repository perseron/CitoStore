#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

# Repopulate the live config + NAS creds from the authoritative NVMe shadow copy.
restore_shadow_conf

SHADOW_CREDS=/srv/vision_mirror/.state/vision-nas.creds
# No .state (NVMe not mounted): nothing to sync, and the cp into it must not
# abort this script — vision-gw-config failing takes everything that wants it down.
if [[ ! -d "$(dirname "$SHADOW_CREDS")" ]]; then
  log "mirror state dir missing (NVMe not mounted?); NAS creds not synced"
elif [[ -f "$SHADOW_CREDS" ]]; then
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
: "${RTC_SYNC_INTERVAL:=10min}"

write_gateway_env

# Update timer override from config.
SYNC_TIMER_DIR=/etc/systemd/system/vision-sync.timer.d
SYNC_TIMER_OVERRIDE=$SYNC_TIMER_DIR/override.conf
mkdir -p "$SYNC_TIMER_DIR"
# Each override first clears the base unit's values (empty assignment): timer
# settings ACCUMULATE across drop-ins, so without the reset the base unit's
# 2min kept firing too — a configured interval longer than the base never
# took effect.
cat > "$SYNC_TIMER_OVERRIDE" <<EOF
[Timer]
OnBootSec=
OnActiveSec=
OnUnitActiveSec=
OnBootSec=$SYNC_ONBOOT_SEC
OnActiveSec=$SYNC_ONACTIVE_SEC
OnUnitActiveSec=$SYNC_INTERVAL_SEC
EOF

SYNC_FAST_TIMER_DIR=/etc/systemd/system/vision-sync-fast.timer.d
SYNC_FAST_TIMER_OVERRIDE=$SYNC_FAST_TIMER_DIR/override.conf
mkdir -p "$SYNC_FAST_TIMER_DIR"
cat > "$SYNC_FAST_TIMER_OVERRIDE" <<EOF
[Timer]
OnActiveSec=
OnUnitActiveSec=
OnActiveSec=$SYNC_HI_INTERVAL_SEC
OnUnitActiveSec=$SYNC_HI_INTERVAL_SEC
EOF

# The RTC/clock-persist cadence must be re-applied from config on every boot
# too — 40_install_services.sh only writes it at install time, so a config
# change (or the overlay dropping the tmpfs copy) silently reverted it.
RTC_TIMER_DIR=/etc/systemd/system/vision-rtc-sync.timer.d
RTC_TIMER_OVERRIDE=$RTC_TIMER_DIR/override.conf
mkdir -p "$RTC_TIMER_DIR"
cat > "$RTC_TIMER_OVERRIDE" <<EOF
[Timer]
OnBootSec=
OnUnitActiveSec=
OnBootSec=5min
OnUnitActiveSec=$RTC_SYNC_INTERVAL
EOF

systemctl daemon-reload
# try-restart only: pick up the new intervals on timers that are running, but
# never START one. "restart" started the fast 10s timer (owned by the monitor,
# off by design) on every boot and every Save + Apply, and resumed syncs that
# Maintenance Mode had paused. At boot timers.target starts the enabled ones.
systemctl try-restart vision-sync.timer || log "vision-sync.timer try-restart failed"
systemctl try-restart vision-sync-fast.timer >/dev/null 2>&1 || true
systemctl try-restart vision-rtc-sync.timer >/dev/null 2>&1 || true

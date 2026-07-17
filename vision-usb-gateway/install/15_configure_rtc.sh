#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root
load_config

CONFIG_TXT=/boot/firmware/config.txt

# The CM5 only keeps time across a power cut if a backup cell is fitted to the
# carrier's RTC header, and the SoC ships with its charger switched off — so a
# rechargeable cell sits flat forever and the RTC reads back at the epoch. That
# matters here because the unit is offline by design and has no NTP to fall back
# on. 3000000 uV is the value Raspberry Pi document for the official RTC battery
# (RTC-Battery-B / ML2032: 3 V nominal, 3.3 V max); the charger's own limits are
# in /sys/class/rtc/rtc0/charging_voltage_{min,max} (1.3–4.4 V).
#
# Only ever charge a RECHARGEABLE cell (ML2032 / LIR / supercap). Charging a
# primary CR2032 can make it leak or rupture: set RTC_CHARGE_ENABLED=false if
# one is fitted.
RTC_CHARGE_ENABLED=${RTC_CHARGE_ENABLED:-true}
RTC_CHARGE_UV=${RTC_CHARGE_UV:-3000000}

BOOT_MOUNT=/boot/firmware
BOOT_WAS_RO=false

boot_rw() {
  mountpoint -q "$BOOT_MOUNT" || return 0
  local opts
  opts=$(findmnt -no OPTIONS "$BOOT_MOUNT" 2>/dev/null || true)
  if echo ",$opts," | grep -q ",ro,"; then
    BOOT_WAS_RO=true
    log "remounting $BOOT_MOUNT read-write"
    mount -o remount,rw "$BOOT_MOUNT"
  fi
}

cleanup_boot_mount() {
  if $BOOT_WAS_RO && mountpoint -q "$BOOT_MOUNT"; then
    log "remounting $BOOT_MOUNT read-only"
    mount -o remount,ro "$BOOT_MOUNT" || true
  fi
}
trap cleanup_boot_mount EXIT

if [[ ! -f "$CONFIG_TXT" ]]; then
  log "$CONFIG_TXT not found; skipping rtc battery configuration"
  exit 0
fi

if [[ "$RTC_CHARGE_ENABLED" != "true" ]]; then
  if grep -qE '^dtparam=rtc_bbat_vchg=' "$CONFIG_TXT"; then
    log "RTC_CHARGE_ENABLED=false; removing rtc battery charging"
    boot_rw
    sed -i '/^dtparam=rtc_bbat_vchg=/d' "$CONFIG_TXT"
    log "rtc battery charging removed (takes effect on reboot)"
  else
    log "rtc battery charging not configured; nothing to do"
  fi
  exit 0
fi

if ! [[ "$RTC_CHARGE_UV" =~ ^[0-9]+$ ]] ||
  ((RTC_CHARGE_UV < 1300000 || RTC_CHARGE_UV > 4400000)); then
  log "RTC_CHARGE_UV=$RTC_CHARGE_UV is outside the charger's 1300000-4400000 uV range"
  exit 1
fi

desired="dtparam=rtc_bbat_vchg=$RTC_CHARGE_UV"

if grep -qxF "$desired" "$CONFIG_TXT"; then
  log "rtc battery charging already configured ($desired)"
  exit 0
fi

boot_rw
if grep -qE '^dtparam=rtc_bbat_vchg=' "$CONFIG_TXT"; then
  log "updating rtc battery charge voltage -> ${RTC_CHARGE_UV} uV"
  sed -i "s/^dtparam=rtc_bbat_vchg=.*/$desired/" "$CONFIG_TXT"
else
  log "enabling rtc battery charging at ${RTC_CHARGE_UV} uV"
  echo "$desired" >>"$CONFIG_TXT"
fi

log "rtc battery charging configured (takes effect on reboot)"

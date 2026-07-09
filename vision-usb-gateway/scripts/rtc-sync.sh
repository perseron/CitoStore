#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root
load_config

RTC_ENABLED=${RTC_ENABLED:-false}
RTC_DEVICE=${RTC_DEVICE:-/dev/rtc0}
RTC_UTC=${RTC_UTC:-true}

if [[ "$RTC_ENABLED" != "true" ]]; then
  log "rtc-sync disabled"
  exit 0
fi

if [[ ! -e "$RTC_DEVICE" ]]; then
  log "rtc device not found: $RTC_DEVICE"
  exit 0
fi

if ! command -v hwclock >/dev/null 2>&1; then
  log "hwclock not available"
  exit 1
fi

mode="hctosys"
if [[ ${1:-} == "--systohc" ]]; then
  mode="systohc"
fi
if [[ ${1:-} == "--if-ntp-missing" ]]; then
  mode="hctosys-if-ntp-missing"
fi

if [[ "$RTC_UTC" == "true" ]]; then
  rtc_flag="--utc"
else
  rtc_flag="--localtime"
fi

if [[ "$mode" == "hctosys-if-ntp-missing" ]]; then
  if command -v timedatectl >/dev/null 2>&1; then
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    if [[ "$ntp" == "yes" ]]; then
      log "ntp synchronized; skipping rtc -> system"
      exit 0
    fi
  fi
  log "ntp not synchronized; rtc -> system ($RTC_DEVICE)"
  hwclock --hctosys --rtc "$RTC_DEVICE" "$rtc_flag" || true
elif [[ "$mode" == "hctosys" ]]; then
  log "rtc -> system clock ($RTC_DEVICE)"
  hwclock --hctosys --rtc "$RTC_DEVICE" "$rtc_flag" || true
else
  log "system clock -> rtc ($RTC_DEVICE)"
  hwclock --systohc --rtc "$RTC_DEVICE" "$rtc_flag" || true
fi

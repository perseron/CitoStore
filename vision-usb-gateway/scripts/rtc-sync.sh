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
# An RTC with no backup cell — or a flat one — reads back at the epoch, and
# copying that onto the system clock is worse than the stale-but-plausible time
# the unit booted with. Refuse to move a clock either way across this line.
# 1767225600 = 2026-01-01, after any epoch reading and before any unit shipped.
RTC_MIN_VALID_EPOCH=${RTC_MIN_VALID_EPOCH:-1767225600}

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

# Seconds since the epoch as held by the RTC. sysfs exposes it directly; fall
# back to parsing hwclock where that node is missing. The sysfs value always
# reads as UTC, which is close enough for a "is this the epoch or a real date"
# test even when the RTC is set to localtime.
rtc_epoch() {
  local sysfs="/sys/class/rtc/$(basename "$RTC_DEVICE")/since_epoch"
  if [[ -r "$sysfs" ]]; then
    cat "$sysfs"
    return 0
  fi
  local shown
  shown=$(hwclock --show --rtc "$RTC_DEVICE" "$rtc_flag" 2>/dev/null) || return 1
  date -d "$shown" +%s 2>/dev/null
}

rtc_is_plausible() {
  local epoch
  epoch=$(rtc_epoch) || return 1
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  ((epoch >= RTC_MIN_VALID_EPOCH))
}

hctosys_guarded() {
  if ! rtc_is_plausible; then
    log "rtc reads $(rtc_epoch 2>/dev/null || echo "unreadable") (before $RTC_MIN_VALID_EPOCH) — no backup cell fitted or it is flat; leaving the system clock alone"
    exit 0
  fi
  log "rtc -> system clock ($RTC_DEVICE)"
  hwclock --hctosys --rtc "$RTC_DEVICE" "$rtc_flag" || true
}

if [[ "$mode" == "hctosys-if-ntp-missing" ]]; then
  if command -v timedatectl >/dev/null 2>&1; then
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    if [[ "$ntp" == "yes" ]]; then
      log "ntp synchronized; skipping rtc -> system"
      exit 0
    fi
  fi
  log "ntp not synchronized; considering rtc -> system"
  hctosys_guarded
elif [[ "$mode" == "hctosys" ]]; then
  hctosys_guarded
else
  # Don't overwrite a good RTC with a system clock that is itself bogus (an
  # early boot before anything has set the time, say).
  now=$(date +%s)
  if ((now < RTC_MIN_VALID_EPOCH)); then
    log "system clock reads $now (before $RTC_MIN_VALID_EPOCH); refusing to write it to the rtc"
    exit 0
  fi
  log "system clock -> rtc ($RTC_DEVICE)"
  hwclock --systohc --rtc "$RTC_DEVICE" "$rtc_flag" || true
fi

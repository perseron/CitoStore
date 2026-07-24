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

# Monotonic clock persistence, independent of the RTC: the last known-good
# time is saved to the NVMe (the overlay /etc is tmpfs, which is why
# fake-hwclock resets every boot to the image's bake date), and at boot the
# clock steps FORWARD to it — never backward — so a unit with no cell and no
# NTP only ever loses its powered-off duration, and timestamps stay monotonic
# across reboots. Needs no trust in any external clock.
: "${MIRROR_MOUNT:=/srv/vision_mirror}"
CLOCK_PERSIST_ENABLED=${CLOCK_PERSIST_ENABLED:-true}
CLOCK_PERSIST_FILE=${CLOCK_PERSIST_FILE:-$MIRROR_MOUNT/.state/last-known-time}

if [[ "$RTC_UTC" == "true" ]]; then
  rtc_flag="--utc"
else
  rtc_flag="--localtime"
fi

rtc_usable() {
  [[ "$RTC_ENABLED" == "true" ]] || return 1
  [[ -e "$RTC_DEVICE" ]] || return 1
  command -v hwclock >/dev/null 2>&1
}

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
  rtc_usable || return 0
  if ! rtc_is_plausible; then
    log "rtc reads $(rtc_epoch 2>/dev/null || echo "unreadable") (before $RTC_MIN_VALID_EPOCH) — no backup cell fitted or it is flat; leaving the system clock alone"
    return 0
  fi
  log "rtc -> system clock ($RTC_DEVICE)"
  hwclock --hctosys --rtc "$RTC_DEVICE" "$rtc_flag" || true
}

systohc_guarded() {
  rtc_usable || return 0
  local now
  now=$(date +%s)
  if ((now < RTC_MIN_VALID_EPOCH)); then
    log "system clock reads $now (before $RTC_MIN_VALID_EPOCH); refusing to write it to the rtc"
    return 0
  fi
  log "system clock -> rtc ($RTC_DEVICE)"
  hwclock --systohc --rtc "$RTC_DEVICE" "$rtc_flag" || true
}

persist_save() {
  [[ "$CLOCK_PERSIST_ENABLED" == "true" ]] || return 0
  local dir now
  dir=$(dirname "$CLOCK_PERSIST_FILE")
  [[ -d "$dir" ]] || return 0
  now=$(date +%s)
  ((now >= RTC_MIN_VALID_EPOCH)) || return 0
  printf '%s\n' "$now" > "$CLOCK_PERSIST_FILE.tmp" && mv -f "$CLOCK_PERSIST_FILE.tmp" "$CLOCK_PERSIST_FILE"
}

persist_restore_forward() {
  [[ "$CLOCK_PERSIST_ENABLED" == "true" ]] || return 0
  [[ -r "$CLOCK_PERSIST_FILE" ]] || return 0
  local saved now
  saved=$(head -c 32 "$CLOCK_PERSIST_FILE" 2>/dev/null | tr -d '[:space:]') || return 0
  [[ "$saved" =~ ^[0-9]+$ ]] || return 0
  ((saved >= RTC_MIN_VALID_EPOCH)) || return 0
  now=$(date +%s)
  if ((saved > now)); then
    log "clock-persist: stepping forward $((saved - now))s to the last saved time"
    date -s "@$saved" >/dev/null || true
  fi
}

mode="hctosys"
if [[ ${1:-} == "--systohc" ]]; then
  mode="systohc"
fi
if [[ ${1:-} == "--if-ntp-missing" ]]; then
  mode="hctosys-if-ntp-missing"
fi

if [[ "$mode" == "hctosys-if-ntp-missing" ]]; then
  ntp=""
  if command -v timedatectl >/dev/null 2>&1; then
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  fi
  if [[ "$ntp" == "yes" ]]; then
    log "ntp synchronized; skipping rtc -> system"
  else
    log "ntp not synchronized; considering rtc -> system"
    hctosys_guarded
    # A battery-backed RTC is authoritative; the persisted timestamp only
    # ever improves on it (forward), covering no-cell and flat-cell units.
    persist_restore_forward
  fi
  persist_save
elif [[ "$mode" == "systohc" ]]; then
  systohc_guarded
  persist_save
else
  hctosys_guarded
fi

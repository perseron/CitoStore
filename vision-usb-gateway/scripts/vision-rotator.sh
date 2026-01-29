#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config "${CONF_FILE:-}"

STATE_FILE=/run/vision-rotate.state
ACTIVE_FILE=/run/vision-usb-active

: "${SWITCH_WINDOW_START:=00:00}"
: "${SWITCH_WINDOW_END:=23:59}"

within_window() {
  local now start end
  now=$(date +%H%M)
  start=${SWITCH_WINDOW_START/:/}
  end=${SWITCH_WINDOW_END/:/}
  if [[ $start -le $end ]]; then
    [[ $now -ge $start && $now -le $end ]]
  else
    [[ $now -ge $start || $now -le $end ]]
  fi
}

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

state=$(grep '^state=' "$STATE_FILE" | cut -d= -f2)
active=$(cat "$ACTIVE_FILE" 2>/dev/null || true)

if [[ -z "$state" || -z "$active" ]]; then
  exit 1
fi

do_switch=false
if [[ "$state" == "panic" ]]; then
  do_switch=true
elif [[ "$state" == "rotate_pending" ]]; then
  if within_window; then
    do_switch=true
  fi
fi

if [[ "$do_switch" != "true" ]]; then
  exit 0
fi

old_lv=$(basename "$active")
log "switching USB gadget from $old_lv"

/bin/bash "$(dirname "${BASH_SOURCE[0]}")/usb-gadget.sh" switch

systemctl start "offline-maint@${old_lv}.service"

echo "state=ok" > "$STATE_FILE"
log "rotation complete"

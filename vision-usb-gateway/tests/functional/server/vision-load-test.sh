#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../scripts/common.sh"

require_root
load_config

THRESH_HI=${THRESH_HI:-80}
THRESH_CRIT=${THRESH_CRIT:-92}
META_HI=${META_HI:-70}
META_CRIT=${META_CRIT:-85}
TEST_THRESH=${TEST_THRESH:-5}
CHECK_INTERVAL=${CHECK_INTERVAL:-5}
TIMEOUT=${TIMEOUT:-300}

usage() {
  cat <<'EOF'
vision-load-test.sh [--test-thresh 5] [--timeout 300] [--interval 5]

Runs monitor+rotator using a temporary config with low thresholds.
This allows verifying that rotation occurs once usage crosses the threshold.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-thresh)
      TEST_THRESH="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --interval)
      CHECK_INTERVAL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

ACTIVE_BEFORE=$(cat /run/vision-usb-active 2>/dev/null || true)
if [[ -z "$ACTIVE_BEFORE" ]]; then
  echo "active USB LV not set" >&2
  exit 1
fi

TMP_CONF=$(mktemp)
cp /etc/vision-gw.conf "$TMP_CONF"
sed -i "s/^THRESH_HI=.*/THRESH_HI=$TEST_THRESH/" "$TMP_CONF"
sed -i "s/^THRESH_CRIT=.*/THRESH_CRIT=$TEST_THRESH/" "$TMP_CONF"
sed -i "s/^META_HI=.*/META_HI=$TEST_THRESH/" "$TMP_CONF"
sed -i "s/^META_CRIT=.*/META_CRIT=$TEST_THRESH/" "$TMP_CONF"
sed -i "s/^SWITCH_WINDOW_START=.*/SWITCH_WINDOW_START=00:00/" "$TMP_CONF"
sed -i "s/^SWITCH_WINDOW_END=.*/SWITCH_WINDOW_END=23:59/" "$TMP_CONF"

export CONF_FILE="$TMP_CONF"

echo "Active before: $ACTIVE_BEFORE"
echo "Temporary thresholds: $TEST_THRESH%"

start_ts=$(date +%s)
switched=false

while true; do
  "$SCRIPT_DIR/../../../scripts/vision-monitor.sh" >/dev/null 2>&1 || true
  "$SCRIPT_DIR/../../../scripts/vision-rotator.sh" >/dev/null 2>&1 || true

  active_now=$(cat /run/vision-usb-active 2>/dev/null || true)
  if [[ -n "$active_now" && "$active_now" != "$ACTIVE_BEFORE" ]]; then
    echo "Rotation detected: $ACTIVE_BEFORE -> $active_now"
    switched=true
    break
  fi

  now_ts=$(date +%s)
  if (( now_ts - start_ts > TIMEOUT )); then
    break
  fi

  sleep "$CHECK_INTERVAL"
done

rm -f "$TMP_CONF"

if [[ "$switched" == "true" ]]; then
  exit 0
fi

echo "Rotation did not occur within ${TIMEOUT}s. Ensure the host is generating data." >&2
exit 1

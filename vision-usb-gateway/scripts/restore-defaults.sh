#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

GATEWAY_HOME=${GATEWAY_HOME:-/opt/vision-usb-gateway}
DEFAULT_CONF="$GATEWAY_HOME/conf/vision-gw.conf.example"
STATE_DIR=/srv/vision_mirror/.state

usage() {
  cat <<'EOF'
Usage:
  restore-defaults.sh --i-know-what-im-doing

This restores configuration defaults:
 - /etc/vision-gw.conf from conf/vision-gw.conf.example
 - shadow config in /srv/vision_mirror/.state/vision-gw.conf

Data volumes are NOT modified.
EOF
}

CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --i-know-what-im-doing)
      CONFIRM=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$CONFIRM" != "true" ]]; then
  echo "Refusing to run without --i-know-what-im-doing" >&2
  exit 1
fi

if [[ ! -f "$DEFAULT_CONF" ]]; then
  echo "Default config missing: $DEFAULT_CONF" >&2
  exit 1
fi

cp "$DEFAULT_CONF" /etc/vision-gw.conf
if grep -q '^GATEWAY_HOME=' /etc/vision-gw.conf; then
  sed -i "s#^GATEWAY_HOME=.*#GATEWAY_HOME=$GATEWAY_HOME#" /etc/vision-gw.conf
else
  echo "GATEWAY_HOME=$GATEWAY_HOME" >> /etc/vision-gw.conf
fi

mkdir -p "$STATE_DIR"
cp "$DEFAULT_CONF" "$STATE_DIR/vision-gw.conf"
if grep -q '^GATEWAY_HOME=' "$STATE_DIR/vision-gw.conf"; then
  sed -i "s#^GATEWAY_HOME=.*#GATEWAY_HOME=$GATEWAY_HOME#" "$STATE_DIR/vision-gw.conf"
else
  echo "GATEWAY_HOME=$GATEWAY_HOME" >> "$STATE_DIR/vision-gw.conf"
fi

echo "Defaults restored."

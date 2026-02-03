#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

GATEWAY_HOME=${GATEWAY_HOME:-/opt/vision-usb-gateway}
SHADOW_CONF=/srv/vision_mirror/.state/vision-gw.conf
DEFAULT_CONF="$GATEWAY_HOME/conf/vision-gw.conf.example"

if [[ -f "$SHADOW_CONF" ]]; then
  cp "$SHADOW_CONF" /etc/vision-gw.conf
elif [[ -f "$DEFAULT_CONF" ]]; then
  cp "$DEFAULT_CONF" /etc/vision-gw.conf
fi

SHADOW_CREDS=/srv/vision_mirror/.state/vision-nas.creds
if [[ -f "$SHADOW_CREDS" ]]; then
  cp "$SHADOW_CREDS" /etc/vision-nas.creds
  chmod 0600 /etc/vision-nas.creds
fi

if [[ -f /etc/vision-gw.conf ]]; then
  if grep -q '^GATEWAY_HOME=' /etc/vision-gw.conf; then
    sed -i "s#^GATEWAY_HOME=.*#GATEWAY_HOME=$GATEWAY_HOME#" /etc/vision-gw.conf
  else
    echo "GATEWAY_HOME=$GATEWAY_HOME" >> /etc/vision-gw.conf
  fi
fi

"$GATEWAY_HOME/scripts/update-config.sh"
"$GATEWAY_HOME/install/50_configure_samba.sh"

if grep -q '^NAS_ENABLED=true' /etc/vision-gw.conf 2>/dev/null; then
  "$GATEWAY_HOME/install/60_configure_nas_optional.sh"
else
  systemctl disable --now mnt-nas.automount nas-sync.timer || true
fi

systemctl restart vision-webui.service || true

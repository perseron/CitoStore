#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root
load_config

TEMPLATE="$SCRIPT_DIR/../conf/samba/smb.conf.template"
OUT=/etc/samba/smb.conf

SMB_BIND_INTERFACE=${SMB_BIND_INTERFACE:-eth0}
SMB_GUEST_OK=${SMB_GUEST_OK:-yes}

sed -e "s/{{SMB_BIND_INTERFACE}}/$SMB_BIND_INTERFACE/" -e "s/{{SMB_GUEST_OK}}/$SMB_GUEST_OK/" "$TEMPLATE" > "$OUT"

systemctl enable smbd
systemctl restart smbd

log "samba configured"
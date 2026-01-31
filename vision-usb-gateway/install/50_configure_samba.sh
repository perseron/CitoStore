#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root
load_config

TEMPLATE="$SCRIPT_DIR/../conf/samba/smb.conf.template"
OUT=/etc/samba/smb.conf
SMBD_OVERRIDE_DIR=/etc/systemd/system/smbd.service.d
SMBD_OVERRIDE_FILE=$SMBD_OVERRIDE_DIR/override.conf

SMB_BIND_INTERFACE=${SMB_BIND_INTERFACE:-eth0}
SMB_GUEST_OK=${SMB_GUEST_OK:-no}
SMB_USER=${SMB_USER:-smbuser}
SMB_PASS=${SMB_PASS:-}
NETBIOS_NAME=${NETBIOS_NAME:-CITOSTORE}
SMB_WORKGROUP=${SMB_WORKGROUP:-WORKGROUP}

sed -e "s/{{SMB_BIND_INTERFACE}}/$SMB_BIND_INTERFACE/" \
  -e "s/{{SMB_GUEST_OK}}/$SMB_GUEST_OK/" \
  -e "s/{{SMB_USER}}/$SMB_USER/" \
  -e "s/{{NETBIOS_NAME}}/$NETBIOS_NAME/" \
  -e "s/{{SMB_WORKGROUP}}/$SMB_WORKGROUP/" \
  "$TEMPLATE" > "$OUT"

if ! id -u "$SMB_USER" >/dev/null 2>&1; then
  useradd -M -s /usr/sbin/nologin "$SMB_USER"
fi

if [[ -n "$SMB_PASS" ]]; then
  printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | smbpasswd -s -a "$SMB_USER"
  smbpasswd -e "$SMB_USER"
else
  log "SMB_PASS not set; skipping smbpasswd setup for $SMB_USER"
fi

chown -R "$SMB_USER":nogroup /srv/vision_mirror
chmod -R 2775 /srv/vision_mirror

mkdir -p "$SMBD_OVERRIDE_DIR"
cat > "$SMBD_OVERRIDE_FILE" <<'EOF'
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
RestartSec=10
EOF

if systemctl is-active --quiet NetworkManager; then
  systemctl enable --now NetworkManager-wait-online.service
elif systemctl is-active --quiet systemd-networkd; then
  systemctl enable --now systemd-networkd-wait-online.service
fi

systemctl daemon-reload
systemctl enable smbd nmbd
systemctl restart smbd nmbd
systemctl enable --now wsdd.service || true

log "samba configured"

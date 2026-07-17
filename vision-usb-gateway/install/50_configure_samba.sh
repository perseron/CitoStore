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
SMB_USER=${SMB_USER:-smbuser}
SMB_PASS=${SMB_PASS:-}
NETBIOS_NAME=${NETBIOS_NAME:-CITOSTORE}
SMB_WORKGROUP=${SMB_WORKGROUP:-WORKGROUP}
MIRROR_MOUNT=${MIRROR_MOUNT:-/srv/vision_mirror}
USB_EXPORT_MOUNT=${USB_EXPORT_MOUNT:-/srv/usb_backup}
SAMBA_LIB=/var/lib/samba
SAMBA_PERSIST="$MIRROR_MOUNT/.state/samba"

# Overlay-safe Samba persistence: bind /var/lib/samba (passdb.tdb = SMB
# users/passwords, secrets.tdb) onto the NVMe mirror. Without this the SMB
# password lives on the read-only overlay root and is lost on every reboot.
setup_samba_persist() {
  if mountpoint -q "$SAMBA_LIB"; then
    log "samba state already bind-mounted to persistent storage"
    return 0
  fi
  if ! mountpoint -q "$MIRROR_MOUNT"; then
    log "mirror not mounted; skipping samba persistence bind (will bind on boot)"
  fi
  safe_mkdir "$SAMBA_PERSIST"
  # Seed once from the package's initial state so tdb databases exist.
  if [[ -z "$(ls -A "$SAMBA_PERSIST" 2>/dev/null)" ]]; then
    cp -a "$SAMBA_LIB/." "$SAMBA_PERSIST/" 2>/dev/null || true
  fi
  install -m 0644 "$SCRIPT_DIR/../systemd/var-lib-samba.mount" \
    /etc/systemd/system/var-lib-samba.mount
  systemctl daemon-reload
  systemctl enable var-lib-samba.mount >/dev/null 2>&1 || true
  # Activate now so the smbpasswd below writes to the persistent copy.
  systemctl start var-lib-samba.mount || mount --bind "$SAMBA_PERSIST" "$SAMBA_LIB"
  log "samba state bound to $SAMBA_PERSIST (overlay-safe)"
}
setup_samba_persist

# USB_EXPORT_MOUNT is a path, so it carries slashes — use a separator sed will
# not confuse for one.
sed -e "s/{{SMB_BIND_INTERFACE}}/$SMB_BIND_INTERFACE/" \
  -e "s/{{SMB_USER}}/$SMB_USER/" \
  -e "s/{{NETBIOS_NAME}}/$NETBIOS_NAME/" \
  -e "s/{{SMB_WORKGROUP}}/$SMB_WORKGROUP/" \
  -e "s#{{USB_EXPORT_MOUNT}}#$USB_EXPORT_MOUNT#" \
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

chown root:root /srv/vision_mirror
chmod 0755 /srv/vision_mirror
chown -R root:root /srv/vision_mirror/.state /srv/vision_mirror/raw /srv/vision_mirror/bydate 2>/dev/null || true
chmod 0755 /srv/vision_mirror/raw /srv/vision_mirror/bydate 2>/dev/null || true
# .state holds secrets (ftp.creds, webui.secret/passwd, vision-nas.creds, the
# Samba passdb/secrets tdbs) right under the SMB-shared mirror root. It must NOT
# be world-readable: the share forces access as SMB_USER, so 0700 root on .state
# stops that user traversing into it (belt-and-suspenders with `veto files` in
# smb.conf). A previous blanket `find .state -exec chmod 0644` re-published every
# secret on each boot; do NOT reintroduce it.
chmod 0700 /srv/vision_mirror/.state 2>/dev/null || true
for secret in ftp.creds webui.secret webui.passwd vision-nas.creds network.json; do
  [[ -f "/srv/vision_mirror/.state/$secret" ]] && chmod 0600 "/srv/vision_mirror/.state/$secret"
done
if [[ -d /srv/vision_mirror/.state/samba/private ]]; then
  chmod 0700 /srv/vision_mirror/.state/samba/private
  find /srv/vision_mirror/.state/samba/private -type f -exec chmod 0600 {} \; 2>/dev/null || true
fi

mkdir -p "$SMBD_OVERRIDE_DIR"
cat > "$SMBD_OVERRIDE_FILE" <<'EOF'
[Unit]
Wants=network-online.target
After=network-online.target
# Ensure the overlay-safe Samba state bind mount is in place before smbd,
# so passdb.tdb (SMB passwords) is read/written on the persistent NVMe copy.
RequiresMountsFor=/var/lib/samba

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
systemctl restart smbd
# nmbd (NetBIOS only) fails if no network interface is up yet (e.g. cable not
# plugged in at boot). Don't let that abort this script under `set -e` and take
# apply-shadow-config (and the ingest config after it) down with it; its
# Restart=on-failure drop-in brings it up once an interface appears.
systemctl restart nmbd || log "nmbd restart deferred (no network interface yet); will retry"
systemctl enable --now wsdd.service || true

log "samba configured"

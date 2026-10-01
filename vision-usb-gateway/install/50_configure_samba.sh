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
SMB_CONF_CHANGED=false
sed -e "s/{{SMB_BIND_INTERFACE}}/$SMB_BIND_INTERFACE/" \
  -e "s/{{SMB_USER}}/$SMB_USER/" \
  -e "s/{{NETBIOS_NAME}}/$NETBIOS_NAME/" \
  -e "s/{{SMB_WORKGROUP}}/$SMB_WORKGROUP/" \
  -e "s#{{USB_EXPORT_MOUNT}}#$USB_EXPORT_MOUNT#" \
  "$TEMPLATE" | write_if_changed "$OUT" && SMB_CONF_CHANGED=true

if ! id -u "$SMB_USER" >/dev/null 2>&1; then
  useradd -M -s /usr/sbin/nologin "$SMB_USER"
fi

set_smb_password() {  # <password>
  printf '%s\n%s\n' "$1" "$1" | smbpasswd -s -a "$SMB_USER" >/dev/null
  smbpasswd -e "$SMB_USER" >/dev/null
  # Mirror FTP (80_configure_mirror_ftp.sh) authenticates as this same user via
  # PAM/chpasswd, not smbpasswd's own passdb — keep both in sync.
  printf '%s:%s\n' "$SMB_USER" "$1" | chpasswd
}

# Factory default SMB password. A unit with no SMB user in its passdb (fresh
# NVMe, factory reset, a wipe of old) had an unusable share — and no USB-export
# login, which uses the SMB password — until someone set one in the WebUI. Only
# when SMB_USER has NO passdb entry: a password set in the WebUI is never
# overwritten. Change it after installation (WebUI -> SMB password).
DEFAULT_SMB_PASS=citostore
SMB_UNIX_CREDS="$MIRROR_MOUNT/.state/smb_unix.creds"

if [[ -n "$SMB_PASS" ]]; then
  set_smb_password "$SMB_PASS"
elif ! pdbedit -L -u "$SMB_USER" >/dev/null 2>&1; then
  # Into the NVMe passdb only (the bind above): seeded into the overlay's RAM
  # copy it would vanish at reboot — the next boot with the bind does it.
  if mountpoint -q "$SAMBA_LIB" && [[ -d "$MIRROR_MOUNT/.state" ]]; then
    # A password the WebUI set earlier survives in smb_unix.creds even when the
    # passdb lost the user: bring that one back rather than the default, so SMB
    # and the mirror FTP (PAM, re-applied from the creds) keep one password.
    # "|| true": no creds file makes sed fail, and under pipefail that aborted
    # the whole script (set -e) before any password was set.
    pw=$(sed -n 's/^password=//p' "$SMB_UNIX_CREDS" 2>/dev/null | head -1 || true)
    if [[ -n "$pw" ]]; then
      set_smb_password "$pw"
      log "no SMB user in the passdb: recreated $SMB_USER with its saved password"
    else
      set_smb_password "$DEFAULT_SMB_PASS"
      # The PAM copy is re-applied from here on every boot (/etc/shadow is on
      # the overlay).
      (umask 077; printf 'password=%s\n' "$DEFAULT_SMB_PASS" > "$SMB_UNIX_CREDS")
      log "no SMB user in the passdb: created $SMB_USER with the default password (change it in the WebUI)"
    fi
  else
    log "no SMB user yet, but the Samba state is not on the NVMe; default password on the next boot"
  fi
fi

chown root:root /srv/vision_mirror
chmod 0755 /srv/vision_mirror
# raw/ and bydate/ themselves only: a recursive chown walked (and dirtied the
# ctime of) every captured image on each boot and each Save + Apply. The sync
# writes them as root anyway; .state is small and holds the secrets.
chown root:root /srv/vision_mirror/raw /srv/vision_mirror/bydate 2>/dev/null || true
chown -R root:root /srv/vision_mirror/.state 2>/dev/null || true
chmod 0755 /srv/vision_mirror/raw /srv/vision_mirror/bydate 2>/dev/null || true
# .state holds secrets (ftp.creds, webui.secret/passwd, vision-nas.creds, the
# Samba passdb/secrets tdbs) right under the SMB-shared mirror root. It must NOT
# be world-readable: the share forces access as SMB_USER, so 0700 root on .state
# stops that user traversing into it (belt-and-suspenders with `veto files` in
# smb.conf). A previous blanket `find .state -exec chmod 0644` re-published every
# secret on each boot; do NOT reintroduce it.
chmod 0700 /srv/vision_mirror/.state 2>/dev/null || true
for secret in ftp.creds smb_unix.creds webui.secret webui.passwd vision-nas.creds network.json; do
  [[ -f "/srv/vision_mirror/.state/$secret" ]] && chmod 0600 "/srv/vision_mirror/.state/$secret"
done
if [[ -d /srv/vision_mirror/.state/samba/private ]]; then
  chmod 0700 /srv/vision_mirror/.state/samba/private
  find /srv/vision_mirror/.state/samba/private -type f -exec chmod 0600 {} \; 2>/dev/null || true
fi

mkdir -p "$SMBD_OVERRIDE_DIR"
write_if_changed "$SMBD_OVERRIDE_FILE" <<'EOF' && SMB_CONF_CHANGED=true
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

# Enable only — never start it here. This script also runs at boot (via
# vision-shadow-config) and on every WebUI apply; on a unit with no DHCP answer
# yet (direct 1-1 laptop link, no cable) starting wait-online blocks ~15s and
# fails, and under `set -e` that aborted this script and apply-shadow-config
# with it: ingest, mDNS and mirror FTP were never re-applied on such a boot.
if systemctl is-active --quiet NetworkManager; then
  systemctl enable NetworkManager-wait-online.service
elif systemctl is-active --quiet systemd-networkd; then
  systemctl enable systemd-networkd-wait-online.service
fi

systemctl daemon-reload
systemctl enable smbd nmbd
# Only on a real config change (or when it is not running): a restart drops
# every connected SMB client, including a server-side copy to a USB drive in
# progress, and this runs on every boot and every Save + Apply.
restart_if_needed "$SMB_CONF_CHANGED" smbd
# nmbd (NetBIOS only) fails if no network interface is up yet (e.g. cable not
# plugged in at boot). Don't let that abort this script under `set -e` and take
# apply-shadow-config (and the ingest config after it) down with it; its
# Restart=on-failure drop-in brings it up once an interface appears.
# --no-block: with no address yet (a direct laptop link before 10.10.10.1
# exists) nmbd cannot become ready and the blocking restart held this script —
# and the whole boot applier — for ~50 s.
if [[ "$SMB_CONF_CHANGED" == true ]] || ! systemctl is-active --quiet nmbd; then
  systemctl --no-block restart nmbd || log "nmbd restart deferred (no network interface yet); will retry"
fi
systemctl enable --now wsdd.service || true

log "samba configured"

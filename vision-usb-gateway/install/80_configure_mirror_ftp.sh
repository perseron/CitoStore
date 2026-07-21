#!/usr/bin/env bash
set -euo pipefail

# Read-only FTP export of the mirror on eth0 (the main LAN) — the same data
# the [vision_mirror] SMB share exposes, offered over a second protocol for
# when SMB isn't reliable enough on a given client. Idempotent and
# overlay-safe: called by apply-shadow-config on every boot, driven entirely
# by /etc/vision-gw.conf. Authenticates as the SAME user/password as the SMB
# share (SMB_USER) — one credential for both protocols; 50_configure_samba.sh
# always runs first and owns account creation + the Samba passdb side, this
# script only relies on its PAM-visible (chpasswd) copy of the password. This
# is a SECOND, independent vsftpd instance from the Ethernet-AOI ingest FTP
# (70_configure_ingest.sh) — different interface, different config file,
# different systemd unit, different user — so neither can ever see the
# other's login list.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root
load_config

: "${MIRROR_FTP_ENABLED:=false}"
: "${SMB_USER:=smbuser}"
: "${MIRROR_FTP_BIND_INTERFACE:=eth0}"
: "${MIRROR_FTP_PASV_MIN_PORT:=30021}"
: "${MIRROR_FTP_PASV_MAX_PORT:=30040}"
: "${MIRROR_MOUNT:=/srv/vision_mirror}"

VSFTPD_CONF=/etc/vsftpd-mirror.conf
USERLIST=/etc/vsftpd-mirror.userlist
UNIT=vsftpd-mirror.service

iface_ipv4() {
  ip -o -4 addr show "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

configure_mirror_ftp() {
  if [[ "$MIRROR_FTP_ENABLED" != "true" ]]; then
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    return 0
  fi
  if ! command -v vsftpd >/dev/null 2>&1; then
    log "installing vsftpd"
    DEBIAN_FRONTEND=noninteractive apt-get install -y vsftpd >/dev/null 2>&1 || {
      log "vsftpd install failed"; return 0; }
  fi
  # vsftpd's pam_shells rejects users whose login shell is not in /etc/shells;
  # SMB_USER intentionally uses nologin (set up by 50_configure_samba.sh).
  grep -qxF /usr/sbin/nologin /etc/shells 2>/dev/null || echo /usr/sbin/nologin >> /etc/shells
  # vsftpd chdir()s to the account's real Unix home BEFORE chroot_local_user/
  # local_root take over; SMB_USER's home from 50_configure_samba.sh's
  # `useradd -M` is /home/$SMB_USER, which is never created, so login fails
  # with "500 OOPS: cannot change directory". Same fix as the ingest FTP user
  # in 70_configure_ingest.sh: point the home at the directory we actually
  # serve.
  usermod -d "$MIRROR_MOUNT" "$SMB_USER" >/dev/null 2>&1 || true
  local bind_ip
  bind_ip=$(iface_ipv4 "$MIRROR_FTP_BIND_INTERFACE")
  if [[ -z "$bind_ip" ]]; then
    log "no IPv4 on $MIRROR_FTP_BIND_INTERFACE yet; vsftpd-mirror will fail to bind until it appears (unit has Restart=on-failure)"
    bind_ip="0.0.0.0"
  fi
  cat > "$VSFTPD_CONF" <<EOF
listen=YES
listen_ipv6=NO
listen_address=$bind_ip
anonymous_enable=NO
local_enable=YES
write_enable=NO
local_umask=022
use_localtime=YES
chroot_local_user=YES
allow_writeable_chroot=NO
local_root=$MIRROR_MOUNT
user_sub_token=$SMB_USER
userlist_enable=YES
userlist_file=$USERLIST
userlist_deny=NO
# .state holds secrets (FTP/NAS creds, WebUI secret, Samba passdb) and is
# already root-only (0700) so this user cannot read into it regardless; hidden
# from listings too, same defense-in-depth as the SMB share's "veto files".
hide_file={.state}
pasv_enable=YES
pasv_address=$bind_ip
pasv_min_port=$MIRROR_FTP_PASV_MIN_PORT
pasv_max_port=$MIRROR_FTP_PASV_MAX_PORT
seccomp_sandbox=NO
pam_service_name=vsftpd
EOF
  echo "$SMB_USER" > "$USERLIST"
  systemctl enable "$UNIT" >/dev/null 2>&1 || true
  systemctl restart "$UNIT" >/dev/null 2>&1 || log "$UNIT restart failed"
}

configure_mirror_ftp
log "mirror FTP configured (enabled=$MIRROR_FTP_ENABLED iface=$MIRROR_FTP_BIND_INTERFACE user=$SMB_USER)"

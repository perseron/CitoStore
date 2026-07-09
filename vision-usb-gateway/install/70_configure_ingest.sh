#!/usr/bin/env bash
set -euo pipefail

# Configure the second Ethernet (eth1) and the direct FTP/SFTP ingest path for
# an Ethernet AOI. Idempotent and overlay-safe: called by apply-shadow-config
# on every boot, driven entirely by /etc/vision-gw.conf. The FTP password is a
# secret on the NVMe (never in the shell-sourced config).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root
load_config

: "${ETH1_ENABLED:=false}"
: "${ETH1_INTERFACE:=eth1}"
: "${ETH1_ADDRESS:=192.168.100.1}"
: "${ETH1_PREFIX:=24}"
: "${ETH1_GATEWAY:=}"
: "${INGEST_ENABLED:=false}"
: "${INGEST_DIR:=/srv/vision_mirror/ingest}"
: "${FTP_ENABLED:=false}"
: "${SFTP_ENABLED:=false}"
: "${FTP_USER:=aoiftp}"
: "${FTP_BIND_INTERFACE:=eth1}"
: "${FTP_PASV_MIN_PORT:=30000}"
: "${FTP_PASV_MAX_PORT:=30020}"
: "${MIRROR_MOUNT:=/srv/vision_mirror}"

FTP_CREDS="$MIRROR_MOUNT/.state/ftp.creds"
SFTP_DROPIN=/etc/ssh/sshd_config.d/vision-sftp.conf
VSFTPD_CONF=/etc/vsftpd.conf

# ---------------- eth1 static network ----------------
configure_eth1() {
  command -v nmcli >/dev/null 2>&1 || { log "nmcli missing; cannot configure $ETH1_INTERFACE"; return 0; }
  local con="vision-$ETH1_INTERFACE"
  if [[ "$ETH1_ENABLED" != "true" ]]; then
    nmcli connection down "$con" >/dev/null 2>&1 || true
    return 0
  fi
  if ! nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$con"; then
    nmcli connection add type ethernet con-name "$con" ifname "$ETH1_INTERFACE" >/dev/null 2>&1 || true
  fi
  nmcli connection modify "$con" \
    connection.interface-name "$ETH1_INTERFACE" \
    ipv4.method manual \
    ipv4.addresses "$ETH1_ADDRESS/$ETH1_PREFIX" \
    ipv4.gateway "${ETH1_GATEWAY:-}" \
    ipv4.never-default yes \
    ipv6.method ignore >/dev/null 2>&1 || true
  nmcli connection up "$con" >/dev/null 2>&1 || \
    log "$ETH1_INTERFACE configured ($ETH1_ADDRESS/$ETH1_PREFIX); will activate on carrier"
}

# ---------------- ingest user + directories ----------------
setup_ingest_dirs_user() {
  # Chroot root must be root-owned and non-writable (SFTP + vsftpd requirement);
  # the AOI writes into the data/ subdir.
  safe_mkdir "$INGEST_DIR"
  chown root:root "$INGEST_DIR"
  chmod 0755 "$INGEST_DIR"
  safe_mkdir "$INGEST_DIR/data"
  if ! id -u "$FTP_USER" >/dev/null 2>&1; then
    useradd -M -d "$INGEST_DIR" -s /usr/sbin/nologin "$FTP_USER"
  fi
  usermod -d "$INGEST_DIR" "$FTP_USER" >/dev/null 2>&1 || true
  chown "$FTP_USER":"$FTP_USER" "$INGEST_DIR/data"
  chmod 0755 "$INGEST_DIR/data"
  # Apply the password from the NVMe secret (overlay-safe; not in shell config).
  if [[ -f "$FTP_CREDS" ]]; then
    local pw
    pw=$(grep -E '^password=' "$FTP_CREDS" | cut -d= -f2- || true)
    if [[ -n "$pw" ]]; then
      printf '%s:%s\n' "$FTP_USER" "$pw" | chpasswd
    fi
  fi
}

iface_ipv4() {
  ip -o -4 addr show "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

# ---------------- FTP (vsftpd) ----------------
configure_ftp() {
  if [[ "$FTP_ENABLED" != "true" ]]; then
    systemctl disable --now vsftpd >/dev/null 2>&1 || true
    return 0
  fi
  if ! command -v vsftpd >/dev/null 2>&1; then
    log "installing vsftpd"
    DEBIAN_FRONTEND=noninteractive apt-get install -y vsftpd >/dev/null 2>&1 || {
      log "vsftpd install failed"; return 0; }
  fi
  # vsftpd's pam_shells rejects users whose login shell is not in /etc/shells;
  # the ingest user intentionally uses nologin.
  grep -qxF /usr/sbin/nologin /etc/shells 2>/dev/null || echo /usr/sbin/nologin >> /etc/shells
  local bind_ip
  bind_ip=$(iface_ipv4 "$FTP_BIND_INTERFACE")
  bind_ip=${bind_ip:-$ETH1_ADDRESS}
  cat > "$VSFTPD_CONF" <<EOF
listen=YES
listen_ipv6=NO
listen_address=$bind_ip
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
use_localtime=YES
chroot_local_user=YES
allow_writeable_chroot=NO
local_root=$INGEST_DIR
user_sub_token=$FTP_USER
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
pasv_enable=YES
pasv_address=$bind_ip
pasv_min_port=$FTP_PASV_MIN_PORT
pasv_max_port=$FTP_PASV_MAX_PORT
seccomp_sandbox=NO
pam_service_name=vsftpd
EOF
  echo "$FTP_USER" > /etc/vsftpd.userlist
  systemctl enable vsftpd >/dev/null 2>&1 || true
  systemctl restart vsftpd >/dev/null 2>&1 || log "vsftpd restart failed"
}

# ---------------- SFTP (OpenSSH internal-sftp) ----------------
configure_sftp() {
  if [[ "$SFTP_ENABLED" != "true" ]]; then
    rm -f "$SFTP_DROPIN"
    systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
    return 0
  fi
  mkdir -p "$(dirname "$SFTP_DROPIN")"
  cat > "$SFTP_DROPIN" <<EOF
Match User $FTP_USER
    ChrootDirectory $INGEST_DIR
    ForceCommand internal-sftp -d /data
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOF
  if sshd -t >/dev/null 2>&1; then
    systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
  else
    log "sshd config test failed; removing SFTP drop-in"
    rm -f "$SFTP_DROPIN"
  fi
}

configure_eth1

if [[ "$INGEST_ENABLED" == "true" ]]; then
  setup_ingest_dirs_user
  configure_ftp
  configure_sftp
  log "ingest configured (ftp=$FTP_ENABLED sftp=$SFTP_ENABLED dir=$INGEST_DIR)"
else
  systemctl disable --now vsftpd >/dev/null 2>&1 || true
  rm -f "$SFTP_DROPIN"
  systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
  log "ingest disabled"
fi

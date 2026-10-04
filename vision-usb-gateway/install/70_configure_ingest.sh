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
DEFAULT_FTP_PASS=citostore
SFTP_DROPIN=/etc/ssh/sshd_config.d/vision-sftp.conf
VSFTPD_CONF=/etc/vsftpd.conf

# ---------------- eth1 static network ----------------
configure_eth1() {
  command -v nmcli >/dev/null 2>&1 || { log "nmcli missing; cannot configure $ETH1_INTERFACE"; return 0; }
  local con="vision-$ETH1_INTERFACE"
  if [[ "$ETH1_ENABLED" != "true" ]]; then
    # Delete, not just "down": the profile has autoconnect, so a disabled eth1
    # came straight back up with its old address on the next carrier or boot.
    nmcli connection delete "$con" >/dev/null 2>&1 || true
    return 0
  fi
  # Runtime-only (save no / --temporary), like every other profile here: this
  # runs on every boot, and a saved profile written on the overlay-off first
  # boot after a flash lands on the eMMC and outlives the config (eth1 disabled,
  # factory reset). config + this script are the persistent truth.
  if ! nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$con"; then
    nmcli connection add save no type ethernet con-name "$con" ifname "$ETH1_INTERFACE" >/dev/null 2>&1 || true
  fi
  # IPv6 "disabled", not "ignore": with ignore the kernel still ran SLAAC on
  # eth1 — seen on a home switch: a ULA address from the router's RA; behind an
  # IPv6 router also a default route, so IPv6 traffic left through the AOI
  # link. The AOI talks IPv4 (FTP/SFTP to ETH1_ADDRESS) only.
  # Not "|| true": a value NetworkManager refuses (e.g. an IPv6 address — the
  # WebUI now validates, but a config import can still carry one) left eth1 on
  # its OLD address while Save + Apply reported success. FTP/SFTP are still configured below; the
  # script exits 1 at the end, so the apply reports the failure.
  local err
  if ! err=$(nmcli connection modify --temporary "$con" \
      connection.interface-name "$ETH1_INTERFACE" \
      ipv4.method manual \
      ipv4.addresses "$ETH1_ADDRESS/$ETH1_PREFIX" \
      ipv4.gateway "${ETH1_GATEWAY:-}" \
      ipv4.never-default yes \
      ipv6.method disabled 2>&1); then
    log "ERROR: $ETH1_INTERFACE settings $ETH1_ADDRESS/$ETH1_PREFIX gw=${ETH1_GATEWAY:-none} refused: $err"
    ETH1_FAILED=true
    return 0
  fi
  # Bounded activation (-w 8): eth1 is a point-to-point link to the AOI which may
  # have no carrier at boot; without a wait cap `nmcli up` blocks ~90s. NM keeps
  # autoconnect, so it still comes up on its own when carrier appears.
  nmcli -w 8 connection up "$con" >/dev/null 2>&1 || \
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
  # The AOI's settings folder (common.sh ingest_settings_dir): writable by the
  # AOI, never pruned. Files restored from a wipe backup or a config bundle come
  # in as root — hand them back, without walking the tree when all is right.
  local settings
  settings=$(ingest_settings_dir)
  safe_mkdir "$settings"
  chmod 0755 "$settings"
  find "$settings" \( ! -user "$FTP_USER" -o ! -group "$FTP_USER" \) \
    -exec chown "$FTP_USER":"$FTP_USER" {} + 2>/dev/null || true
  # Factory default ingest password (FTP + SFTP), like the SMB one. Without a
  # password set in the WebUI the account kept whatever the golden image was
  # built with — unknown to whoever sets up the AOI. Written to the NVMe secret
  # once (only with the mirror mounted: the secret lives there), so it is
  # re-applied on every boot below and the WebUI changes it as before; a
  # password already set is never touched.
  if [[ ! -f "$FTP_CREDS" ]] && mountpoint -q "$MIRROR_MOUNT" && [[ -d "$(dirname "$FTP_CREDS")" ]]; then
    (umask 077; printf 'password=%s\n' "$DEFAULT_FTP_PASS" > "$FTP_CREDS")
    log "no ingest password set: $FTP_USER gets the default password (change it in the WebUI)"
  fi
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
  # "|| true": a missing interface makes ip exit 1 and, under pipefail, the
  # caller's $(...) aborted this script before its fallback could apply.
  { ip -o -4 addr show "$1" 2>/dev/null || true; } | awk '{print $4; exit}' | cut -d/ -f1
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
  allow_nonlocal_bind
  local changed=false
  write_if_changed "$VSFTPD_CONF" <<EOF && changed=true
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
  echo "$FTP_USER" | write_if_changed /etc/vsftpd.userlist && changed=true
  systemctl enable vsftpd >/dev/null 2>&1 || true
  # Not on every apply: a restart kills an AOI upload in progress.
  restart_if_needed "$changed" vsftpd >/dev/null 2>&1 || log "vsftpd restart failed"
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

ETH1_FAILED=false
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

if [[ "$ETH1_FAILED" == true ]]; then
  exit 1
fi

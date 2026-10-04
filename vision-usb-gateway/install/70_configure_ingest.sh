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
: "${SMB_USER:=smbuser}"
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
  # Duplicate address detection (dad-timeout, ms): NetworkManager's default is
  # none — it took an address another host on the cable already had (checked on
  # this NM). A LAN cable in the AOI port then made the unit claim
  # 192.168.100.1, a common router address, and cut that LAN off its gateway.
  # With it, NM refuses the address instead (seen in its log as "IPv4 address
  # ... is used on network ... from host <MAC>"); costs ~1 s per activation.
  # Not "|| true": a value NetworkManager refuses (e.g. an IPv6 address — the
  # WebUI now validates, but a config import can still carry one) left eth1 on
  # its OLD address while Save + Apply reported success. FTP/SFTP are still configured below; the
  # script exits 1 at the end, so the apply reports the failure.
  local err before after
  local keys=connection.interface-name,ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.never-default,ipv4.dad-timeout,ipv6.method
  before=$(nmcli -g "$keys" connection show "$con" 2>/dev/null || true)
  if ! err=$(nmcli connection modify --temporary "$con" \
      connection.interface-name "$ETH1_INTERFACE" \
      ipv4.method manual \
      ipv4.addresses "$ETH1_ADDRESS/$ETH1_PREFIX" \
      ipv4.gateway "${ETH1_GATEWAY:-}" \
      ipv4.never-default yes \
      ipv4.dad-timeout 1000 \
      ipv6.method disabled 2>&1); then
    log "ERROR: $ETH1_INTERFACE settings $ETH1_ADDRESS/$ETH1_PREFIX gw=${ETH1_GATEWAY:-none} refused: $err"
    ETH1_FAILED=true
    return 0
  fi
  # Already up with exactly these settings: leave it. This runs on every Save +
  # Apply (any section), and re-activating took eth1's address away for ~0.7 s
  # (the duplicate address check) under an AOI upload each time.
  after=$(nmcli -g "$keys" connection show "$con" 2>/dev/null || true)
  if [[ "$after" == "$before" ]] \
     && nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -qxF "$con:$ETH1_INTERFACE"; then
    return 0
  fi
  # Bounded activation (-w 8): eth1 is a point-to-point link to the AOI which may
  # have no carrier at boot; without a wait cap `nmcli up` blocks ~90s. NM keeps
  # autoconnect, so it still comes up on its own when carrier appears.
  local since
  since=$(date +%s)
  if err=$(nmcli -w 8 connection up "$con" 2>&1); then
    return 0
  fi
  if [[ "$(cat "/sys/class/net/$ETH1_INTERFACE/carrier" 2>/dev/null)" != 1 ]]; then
    log "$ETH1_INTERFACE configured ($ETH1_ADDRESS/$ETH1_PREFIX); will activate on carrier"
    return 0
  fi
  # A cable is in, and the address did not come up: report it.
  local used
  used=$(journalctl -u NetworkManager --since "@$since" -o cat --no-pager 2>/dev/null \
    | grep -F "IPv4 address $ETH1_ADDRESS is used on network" | tail -1 || true)
  if [[ -n "$used" ]]; then
    log "ERROR: $ETH1_ADDRESS is already used by another host (${used##*from host }) on the cable in" \
      "$ETH1_INTERFACE — a LAN cable in the AOI port, or the AOI set to the unit's own address;" \
      "$ETH1_INTERFACE left without an address"
  else
    log "ERROR: $ETH1_INTERFACE has a cable but did not come up on $ETH1_ADDRESS/$ETH1_PREFIX: $err"
  fi
  ETH1_FAILED=true
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

# The address FTP and SFTP serve the AOI on: the bind interface's, or eth1's
# configured one while it has none yet (no cable).
ingest_bind_ip() {
  local ip
  ip=$(iface_ipv4 "$FTP_BIND_INTERFACE")
  echo "${ip:-$ETH1_ADDRESS}"
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
  bind_ip=$(ingest_bind_ip)
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

# ---------------- SSH: service accounts + SFTP (OpenSSH internal-sftp) ----------------
# Written whatever is enabled: the restrictions matter most when SFTP is off
# (see render_sshd_service_accounts in common.sh).
configure_ssh_accounts() {
  command -v sshd >/dev/null 2>&1 || return 0
  local sftp_addr=""
  if [[ "$INGEST_ENABLED" == "true" && "$SFTP_ENABLED" == "true" ]]; then
    sftp_addr=$(ingest_bind_ip)
  fi
  mkdir -p "$(dirname "$SFTP_DROPIN")"
  render_sshd_service_accounts "$FTP_USER" "$SMB_USER" "$INGEST_DIR" "$sftp_addr" \
    | write_if_changed "$SFTP_DROPIN" || return 0
  if ! sshd -t >/dev/null 2>&1; then
    log "ERROR: sshd rejected $SFTP_DROPIN; removed (no SFTP, service accounts not restricted)"
    rm -f "$SFTP_DROPIN"
  fi
  systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
}

ETH1_FAILED=false
configure_eth1

if [[ "$INGEST_ENABLED" == "true" ]]; then
  setup_ingest_dirs_user
  configure_ftp
  log "ingest configured (ftp=$FTP_ENABLED sftp=$SFTP_ENABLED dir=$INGEST_DIR)"
else
  systemctl disable --now vsftpd >/dev/null 2>&1 || true
  log "ingest disabled"
fi
configure_ssh_accounts

if [[ "$ETH1_FAILED" == true ]]; then
  exit 1
fi

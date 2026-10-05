#!/usr/bin/env bash
set -euo pipefail

CONF_FILE_DEFAULT=/etc/vision-gw.conf
ENV_FILE_DEFAULT=/etc/vision-gw.env
SHADOW_CONF_DEFAULT=/srv/vision_mirror/.state/vision-gw.conf

# Repository root. Honour an explicit GATEWAY_HOME (systemd units set it via
# EnvironmentFile=/etc/vision-gw.env); otherwise derive it from this file's own
# location (scripts/common.sh -> repo root). This is the single source of truth,
# so no script needs a hard-coded default that can drift from the real path.
GATEWAY_HOME=${GATEWAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

log() {
  echo "[$(date -Is)] $*" >&2
}

# Replace <dest> with stdin only if the content differs. Returns 0 when the file
# changed, 1 when it was already identical. Lets a configurator restart its
# service only on a real change: these scripts run on every boot AND every WebUI
# "Save + Apply" (any section), and an unconditional restart dropped connected
# SMB clients and killed AOI FTP uploads mid-file each time.
write_if_changed() {  # <dest> [mode]
  local dest=$1 mode=${2:-0644} tmp
  tmp=$(mktemp "${dest}.XXXXXX")
  cat > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
  return 0
}

# Restart <unit> when its config changed or it is not running; otherwise leave
# it (and its clients) alone.
restart_if_needed() {  # <changed: true|false> <unit>
  if [[ "$1" == true ]] || ! systemctl is-active --quiet "$2"; then
    systemctl restart "$2"
  else
    log "$2: configuration unchanged and running; not restarted"
  fi
}

# vsftpd binds a single address (ingest on eth1, mirror FTP on eth0). With no
# cable / no lease yet that address does not exist, and it restart-looped every
# 5 s forever (Restart=on-failure, no start limit), flooding the RAM journal.
# Allowing non-local binds lets it bind now and serve once the address appears.
allow_nonlocal_bind() {
  sysctl -q -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1 || true
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
  fi
}

load_config() {
  local conf_file="${1:-$CONF_FILE_DEFAULT}"
  # GATEWAY_HOME is an install-location fact, not user config; never let a value
  # that happens to be in the sourced file override the env/derived one above
  # (an old copy on disk once pointed at a pre-migration path).
  local _gwh="$GATEWAY_HOME"
  if [[ -f "$conf_file" ]]; then
    # shellcheck source=/dev/null
    source "$conf_file"
  else
    log "config not found: $conf_file"
  fi
  GATEWAY_HOME="$_gwh"
}

# Record GATEWAY_HOME in the on-disk config. health-check.sh treats the presence
# of this line as the "config looks structurally valid" marker.
ensure_gateway_home_in_conf() {
  local conf="${1:-$CONF_FILE_DEFAULT}"
  [[ -f "$conf" ]] || return 0
  if grep -q '^GATEWAY_HOME=' "$conf"; then
    sed -i "s#^GATEWAY_HOME=.*#GATEWAY_HOME=$GATEWAY_HOME#" "$conf"
  else
    echo "GATEWAY_HOME=$GATEWAY_HOME" >> "$conf"
  fi
}

# Restore /etc/vision-gw.conf from the authoritative NVMe shadow copy (falling
# back to the packaged example), then re-assert the correct GATEWAY_HOME. This is
# the single place that repopulates the live config from persistent storage.
restore_shadow_conf() {
  # No shadow (NVMe not mounted, or empty): keep the image's own /etc config —
  # the golden, tuned one — rather than replacing it with the generic example.
  local factory src="" content
  if [[ -f "$SHADOW_CONF_DEFAULT" ]]; then
    src=$SHADOW_CONF_DEFAULT
  elif [[ ! -f "$CONF_FILE_DEFAULT" ]] && factory=$(golden_conf); then
    src=$factory
  fi
  if [[ -z "$src" ]]; then
    ensure_gateway_home_in_conf "$CONF_FILE_DEFAULT"
    return 0
  fi
  # The whole new content first (GATEWAY_HOME re-asserted), written over /etc
  # only when it differs, in one go and in place — the same inode: the WebUI's
  # sandbox binds this very file. It used to be cp then sed -i on every boot
  # and every Save + Apply: truncated for a moment while the sync, rotator and
  # monitor source it, and sed -i swapped the inode under the WebUI.
  content=$(sed '/^GATEWAY_HOME=/d' "$src"; echo "GATEWAY_HOME=$GATEWAY_HOME")
  if [[ "$(cat "$CONF_FILE_DEFAULT" 2>/dev/null)" != "$content" ]]; then
    printf '%s\n' "$content" > "$CONF_FILE_DEFAULT"
  fi
}

# The unit's factory configuration: the golden image's own, tuned config — NOT
# the generic packaged example, which has other volume sizes (100G USB LVs in a
# 64G pool), NetBIOS name, sync cadence and switch settings. prepare-golden-image
# keeps a pristine copy in the seed dir; on images baked before that, the
# overlay's read-only lower /etc still holds it.
SEED_CONF=/etc/citostore-seed/vision-gw.conf
golden_conf() {
  local c
  for c in "$SEED_CONF" /media/root-ro/etc/vision-gw.conf "$GATEWAY_HOME/conf/vision-gw.conf.example"; do
    if [[ -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# Set KEY=VALUE in the NVMe shadow config (the copy that survives a reboot under
# the read-only overlay; the WebUI reads it too) and in the live /etc copy.
# Writing /etc alone — as resize/rebalance did — was undone at the next boot.
# VALUE must already be validated: the file is sourced by root scripts.
set_conf_value() {  # <key> <value>
  local key=$1 value=$2 f tmp
  for f in "$SHADOW_CONF_DEFAULT" "$CONF_FILE_DEFAULT"; do
    [[ -f "$f" ]] || continue
    tmp=$(mktemp "$f.XXXXXX")
    awk -v k="$key" -v v="$value" '
      index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }' "$f" > "$tmp"
    if [[ "$f" == "$SHADOW_CONF_DEFAULT" ]]; then
      chmod 0644 "$tmp"
      mv -f "$tmp" "$f"
    else
      # In place (same inode): the WebUI's sandbox bind-mounts this very file.
      cat "$tmp" > "$f"
      rm -f "$tmp"
    fi
  done
}

# .state items that are configuration, not captured data: carried across a
# reformat of the mirror (Wipe All Data, rebalance-storage). Missing one meant
# the unit came back without its passwords, SMB passdb or AOI settings.
STATE_PRESERVE=(
  vision-gw.conf vision-gw.conf.last-good vision-nas.creds network.json
  webui.passwd webui.secret ftp.creds smb_unix.creds samba aoi_settings
  updates update-history.json last-known-time
)
state_backup() {  # <state dir> <backup dir>
  local item
  rm -rf "$2"
  mkdir -p "$2"
  for item in "${STATE_PRESERVE[@]}"; do
    if [[ -e "$1/$item" ]]; then
      cp -a "$1/$item" "$2/"
    fi
  done
}
state_restore() {  # <backup dir> <state dir>
  local item
  mkdir -p "$2"
  for item in "${STATE_PRESERVE[@]}"; do
    if [[ -e "$1/$item" ]]; then
      cp -a "$1/$item" "$2/"
    fi
  done
}

# The AOI keeps its own settings in a folder on the USB drive (USB_PERSIST_DIR,
# default aoi_settings). The unit carries it across reformats through the NVMe
# backing copy (.state/aoi_settings): exported from the drive being reformatted,
# put back onto the fresh one. A drive without the folder — 30_setup only
# formatted the LVs it created at install, first boot, factory reset or a
# self-heal — handed the AOI a drive without its settings until that drive's
# first rotation.
#
# usb_persist_write <lv device> <backing dir> <ensure|replace>
#   ensure   create the folder if it is missing, filled from the backing
#   replace  make the folder an exact copy of the backing (new settings from a
#            bundle must reach every drive, or the next rotation exports the
#            drive's old copy over them)
# Only for a drive NOT exported to the host: a FAT mounted on both sides is
# corrupted. Prints ok | created | restored | replaced; returns 1 when the drive
# could not be mounted.
usb_persist_fs_dev() {
  local dump
  dump=$(sfdisk -d "$1" 2>/dev/null || true)
  if [[ "$dump" == *"label:"* ]]; then
    resolve_usb_device "$1"     # a partitioned (cloned-format) drive
  else
    echo "$1"
  fi
}
usb_persist_write() {
  local dev=$1 backing=$2 mode=$3 dir=${USB_PERSIST_DIR:-aoi_settings}
  local opts=utf8,shortname=mixed,nodev,nosuid,noexec fs mnt status
  if [[ -z "$dir" || "$dir" == none ]]; then
    echo ok
    return 0
  fi
  fs=$(usb_persist_fs_dev "$dev")
  mnt=$(mktemp -d /run/vision-persist.XXXXXX)
  if [[ "$mode" == ensure ]]; then
    if ! mount -t vfat -o "ro,$opts" "$fs" "$mnt" 2>/dev/null; then
      rmdir "$mnt"
      return 1
    fi
    if [[ -d "$mnt/$dir" ]]; then
      umount "$mnt"
      rmdir "$mnt"
      echo ok
      return 0
    fi
    umount "$mnt"
  fi
  if ! mount -t vfat -o "$opts" "$fs" "$mnt" 2>/dev/null; then
    rmdir "$mnt"
    return 1
  fi
  if [[ "$mode" == replace ]]; then
    rm -rf "${mnt:?}/$dir"
    status=replaced
  else
    status=created
  fi
  mkdir -p "$mnt/$dir"
  if [[ -d "$backing" && -n "$(ls -A "$backing" 2>/dev/null)" ]]; then
    # Timestamps kept: the persist manifest (rotator check) hashes size+mtime.
    # No -a: FAT has no owners/modes, and cp then fails on every file.
    if ! cp -r --preserve=timestamps "$backing/." "$mnt/$dir/"; then
      log "copying $backing onto $dev failed"
    elif [[ "$status" == created ]]; then
      status=restored
    fi
  fi
  sync
  umount "$mnt"
  rmdir "$mnt"
  echo "$status"
}

# One switch / export / format of the USB LVs at a time: the rotator (the
# sync's and "Rotate USB Now"'s), offline-maint, Clone USB Format and resize.
# Without it two rotations (an automatic one, then the button) let the
# offline-maint of the first format the drive the second had just handed to
# the AOI. Waits up to $1 seconds (default 25 min); held on fd 8 until the
# script exits. A child run by a holder (VISION_USB_LOCK_HELD=1) shares it.
# The sync's settings preseed only takes it when free (vision_sync).
USB_LOCK_FILE=/run/vision-usb.lock
usb_lock() {
  [[ "${VISION_USB_LOCK_HELD:-}" == 1 ]] && return 0
  exec 8>>"$USB_LOCK_FILE"
  if ! flock -w "${1:-1500}" 8; then
    log "USB drives busy: another switch/export/format still running"
    return 1
  fi
  export VISION_USB_LOCK_HELD=1
}
usb_unlock() {
  [[ "${VISION_USB_LOCK_HELD:-}" == 1 ]] || return 0
  flock -u 8 2>/dev/null || true
  exec 8>&-
  unset VISION_USB_LOCK_HELD
}

# Marker: this LV left the AOI with images not yet exported to the mirror.
# Set by the rotator BEFORE the switch, cleared by offline-maint once exported
# and reformatted. A power cut, a timeout or an error in between used to leave
# the old images on the drive with nothing to finish the job — two rotations
# later the AOI got it back 80-90% full. Health-check (boot) and the rotator
# (before switching to it) finish it.
usb_maint_marker() {  # <lv name>
  echo "${MIRROR_MOUNT:-/srv/vision_mirror}/.state/usb-maint-pending.$1"
}

# True if the LV is blank: no filesystem or partition signature at all — what
# a power cut between discard/create and mkfs leaves (exported anyway before,
# and never reformatted). blkid's "nothing found" (rc 2) only: an I/O error,
# or a drive someone reformatted as exFAT/NTFS (its images are still on it),
# is never taken for blank.
usb_is_blank() {  # <lv device>
  local fs rc=0
  fs=$(resolve_usb_device "$1" 2>/dev/null || echo "$1")
  blkid -p "$fs" >/dev/null 2>&1 || rc=$?
  ((rc == 2))
}

# True if `fsck.fat -a` (output in $1) corrected only bookkeeping, nothing
# damaged: the free-cluster count in FSInfo (Windows and Win98 update it
# lazily, so it is off on the drive the host had when the power went — every
# reboot showed "repaired the FAT"), and the dirty flag set while mounted, with
# the FAT copy that carries it. Lost clusters, broken chains, file sizes, long
# names: real repairs, false here.
fsck_fat_only_bookkeeping() {  # <fsck.fat -a output>
  local line
  while IFS= read -r line; do
    case "$line" in
      "" | "fsck.fat "* | "*** Filesystem was changed ***" | "Writing changes." | *": "*" files, "*" clusters") ;;
      "Free cluster summary wrong ("* | "Free cluster summary uninitialized ("* | "  Auto-correcting." | "  Auto-setting.") ;;
      "Dirty bit is set. Fs was not properly unmounted and some data may be corrupt." | " Automatically removing dirty bit.") ;;
      "FATs differ but appear to be intact." | "  Using first FAT.") ;;
      *) return 1 ;;
    esac
  done <<< "$1"
}

# Record that a drive was recycled without its images on the mirror (same file
# as vision_sync's record_not_saved; shown by export_loss_issues).
record_export_loss() {  # <lv device> <reason>
  local f=${MIRROR_MOUNT:-/srv/vision_mirror}/.state/export-not-saved.json
  printf '{"ts": %s, "dev": "%s", "reason": "%s"}\n' "$(date +%s)" "$1" "${2//\"/\'}" > "$f.tmp" \
    && mv -f "$f.tmp" "$f" || true
  log "EXPORT INCOMPLETE: $1: $2"
}

# The Ethernet AOI's own settings folder: in the FTP/SFTP root next to data/,
# separate from the USB drives' aoi_settings (a unit can serve both kinds of
# AOI). Retention prunes only data/, so nothing here is deleted to make room;
# Wipe All Data and the config bundle carry it like the USB one.
ingest_settings_dir() {
  echo "${INGEST_DIR:-/srv/vision_mirror/ingest}/aoi_settings"
}

ip2int() { local IFS=. a b c d; read -r a b c d <<< "$1"; echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }

# Health issues of the AOI link (eth1), one per line, for vision-monitor:
# - a cable in but no address: NetworkManager refused it (duplicate address
#   detection: another host on that cable has it — a LAN cable in the AOI
#   port). Only once it has lasted 20 s, so an activation in progress never
#   counts;
# - eth0 on a network overlapping eth1's (the AOI subnet chosen first, the unit
#   then installed on a LAN that uses it): replies to the AOI can leave via eth0.
aoi_link_issues() {
  local since_file=${AOI_NOADDR_FILE:-/run/vision-eth1-noaddr}
  local if1=${ETH1_INTERFACE:-eth1} addr=${ETH1_ADDRESS:-} prefix=${ETH1_PREFIX:-24}
  if [[ "${ETH1_ENABLED:-false}" != "true" || ! "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    rm -f "$since_file"
    return 0
  fi
  if [[ "$(cat "/sys/class/net/$if1/carrier" 2>/dev/null)" == 1 ]] \
     && ! ip -4 -o addr show dev "$if1" 2>/dev/null | grep -qF " $addr/"; then
    [[ -f "$since_file" ]] || date +%s > "$since_file" 2>/dev/null || true
    local since
    since=$(cat "$since_file" 2>/dev/null || true)
    [[ "$since" =~ ^[0-9]+$ ]] || since=$(date +%s)
    if (( $(date +%s) - since >= 20 )); then
      echo "AOI link ($if1): cable in, but $addr could not be set - already used by another host on that cable?"
    fi
  else
    rm -f "$since_file"
  fi
  [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix <= 32 )) || return 0
  local cidr p mask
  while read -r cidr; do
    [[ "$cidr" =~ ^[0-9.]+/[0-9]+$ ]] || continue
    p=$(( ${cidr#*/} < prefix ? ${cidr#*/} : prefix ))
    mask=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
    if (( ($(ip2int "${cidr%/*}") & mask) == ($(ip2int "$addr") & mask) )); then
      echo "eth0 is on $cidr, overlapping the AOI link ($addr/$prefix): give eth1 another subnet"
      break
    fi
  done < <(ip -4 -o addr show dev "${MDNS_INTERFACE:-eth0}" 2>/dev/null | awk '{print $4}')
  return 0
}

# The NVMe SMART verdict for the health banner, one "<warn|error>|<message>"
# per line: what nvme-health.sh (every 10 min) found, and whether it is still
# reading at all — a verdict older than 30 min, or none 30 min after boot, means
# nobody is looking at the drive any more.
nvme_health_issues() {
  local f=${NVME_ISSUES_FILE:-/run/vision-nvme.issues} max=${NVME_HEALTH_MAX_AGE_SEC:-1800} age up
  if [[ ! -f "$f" ]]; then
    up=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
    (( up < max )) || echo "warn|NVMe SMART has not been read since boot"
    return 0
  fi
  age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
  (( age <= max )) || echo "warn|NVMe SMART last read $(( age / 60 )) min ago"
  cat "$f"
  return 0
}

# A USB drive recycled without its images on the mirror (written by the sync's
# offline export: mirror full). Shown for a week: "<level>|<message>".
export_loss_issues() {
  local f=${EXPORT_LOSS_FILE:-${MIRROR_MOUNT:-/srv/vision_mirror}/.state/export-not-saved.json}
  [[ -f "$f" ]] || return 0
  local ts dev reason
  ts=$(sed -n 's/.*"ts": *\([0-9]*\).*/\1/p' "$f")
  dev=$(sed -n 's/.*"dev": *"\([^"]*\)".*/\1/p' "$f")
  reason=$(sed -n 's/.*"reason": *"\([^"]*\)".*/\1/p' "$f")
  [[ "$ts" =~ ^[0-9]+$ ]] || return 0
  (( $(date +%s) - ts < 7 * 86400 )) || return 0
  echo "error|USB drive ${dev##*/} was recycled with images NOT saved on $(date -d "@$ts" '+%Y-%m-%d %H:%M'): $reason"
}

# Retention could not bring the mirror back to RETENTION_LO (mirror-retention.sh
# writes retention-blocked.json): what is left is kept on purpose — protected
# folders, the AOI's settings folder. Shown while the mirror is still above the
# target, long before it is full: warn, error from 95%. Full, USB drives are
# recycled without their images (export_loss_issues). "<level>|<message>".
retention_blocked_issues() {
  local m=${MIRROR_MOUNT:-/srv/vision_mirror}
  local f=${RETENTION_BLOCKED_FILE:-$m/.state/retention-blocked.json}
  [[ -f "$f" ]] || return 0
  local target prot undel blocks bfree pct
  target=$(sed -n 's/.*"target": *\([0-9]*\).*/\1/p' "$f")
  prot=$(sed -n 's/.*"protected": *\([0-9]*\).*/\1/p' "$f")
  undel=$(sed -n 's/.*"undeletable": *\([0-9]*\).*/\1/p' "$f")
  [[ "$target" =~ ^[0-9]+$ ]] || target=${RETENTION_LO:-85}
  # Used/total as retention counts it (shutil.disk_usage: blocks - free).
  read -r blocks bfree < <(stat -f -c '%b %f' "$m" 2>/dev/null) || return 0
  [[ "$blocks" =~ ^[0-9]+$ && "$bfree" =~ ^[0-9]+$ ]] && (( blocks > 0 )) || return 0
  pct=$(( (blocks - bfree) * 100 / blocks ))
  (( pct > target )) || return 0
  local why="nothing else may be deleted"
  [[ "${prot:-0}" =~ ^[1-9] ]] && why="$prot protected folder(s) hold the rest"
  [[ "${undel:-0}" =~ ^[1-9] ]] && why="$undel file(s) could not be deleted (see the mirror-retention log)"
  echo "$( ((pct >= 95)) && echo error || echo warn)|Mirror ${pct}% full and retention cannot free space below ${target}%: $why. Full, USB drives are recycled WITHOUT their images - unprotect or copy off and remove data."
}

# sshd drop-in for the service accounts: the ingest user (FTP_USER) and the SMB
# user (SMB_USER) have passwords — factory default "citostore" — and a nologin
# shell, which does not stop SSH: `ssh -N -L` as either opened port forwards
# from the LAN into the AOI network (seen live), and the AOI's SFTP login
# worked on eth0 too. Both get no SSH login and no forwarding at all, except
# the AOI's SFTP, and that only on <sftp address> (eth1's). Prints the file;
# 70_configure_ingest.sh installs it on every boot/apply, the image bake too.
render_sshd_service_accounts() {  # <ftp user> <smb user> <ingest dir> [sftp address]
  local ftp=$1 smb=$2 dir=$3 addr=${4:-}
  echo "# Managed by 70_configure_ingest.sh (render_sshd_service_accounts, scripts/common.sh)."
  # First match wins per keyword: the SFTP block, when present, must come first.
  if [[ -n "$addr" ]]; then
    cat <<EOF
Match User $ftp LocalAddress $addr
    ChrootDirectory $dir
    ForceCommand internal-sftp -d /data
    PasswordAuthentication yes
EOF
  fi
  cat <<EOF
Match User $ftp,$smb
    PasswordAuthentication no
    PubkeyAuthentication no
    KbdInteractiveAuthentication no
    DisableForwarding yes
    PermitTunnel no
    PermitTTY no
EOF
}

# Single source of truth for the systemd env file: ALWAYS the full key set.
# Writing a subset (as the NAS step used to) drops the SMB/WebUI/RTC/sync keys
# other units read via EnvironmentFile. Call after load_config so config values
# win; unset keys fall back to the documented defaults below.
write_gateway_env() {
  cat > "$ENV_FILE_DEFAULT" <<EOF
GATEWAY_HOME=$GATEWAY_HOME
NAS_REMOTE=${NAS_REMOTE:-//nas/vision}
NAS_MOUNT=${NAS_MOUNT:-/mnt/nas}
NAS_CREDENTIALS=${NAS_CREDENTIALS:-/etc/vision-nas.creds}
SMB_BIND_INTERFACE=${SMB_BIND_INTERFACE:-eth0}
SMB_WORKGROUP=${SMB_WORKGROUP:-WORKGROUP}
NETBIOS_NAME=${NETBIOS_NAME:-CITOSTORE}
WEBUI_BIND=${WEBUI_BIND:-0.0.0.0}
WEBUI_PORT=${WEBUI_PORT:-80}
RTC_ENABLED=${RTC_ENABLED:-true}
RTC_DEVICE=${RTC_DEVICE:-/dev/rtc0}
RTC_UTC=${RTC_UTC:-true}
RTC_SYNC_INTERVAL=${RTC_SYNC_INTERVAL:-10min}
SYNC_HI_INTERVAL_SEC=${SYNC_HI_INTERVAL_SEC:-10s}
EOF
}

cmdline_has() {
  local key="$1"
  grep -qE "(^| )${key}(=| )" /boot/firmware/cmdline.txt
}

cmdline_add() {
  local key="$1"
  if ! cmdline_has "$key"; then
    # Escape replacement to avoid breaking sed when key contains #, &, or backslashes.
    local key_escaped
    key_escaped=$(printf '%s' "$key" | sed -e 's/[#&\\]/\\&/g')
    sed -i "1 s#\$# ${key_escaped}#" /boot/firmware/cmdline.txt
  fi
}

append_if_missing() {
  local line="$1" file="$2"
  grep -qF "$line" "$file" || echo "$line" >> "$file"
}

safe_mkdir() {
  local path="$1"
  [[ -d "$path" ]] || mkdir -p "$path"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

resolve_usb_device() {
  local dev="$1"
  local partx_bin=""
  local kpartx_bin=""
  local udevadm_bin=""

  if [[ -x /sbin/partx ]]; then
    partx_bin=/sbin/partx
  elif [[ -x /usr/sbin/partx ]]; then
    partx_bin=/usr/sbin/partx
  fi
  if [[ -n "$partx_bin" ]]; then
    "$partx_bin" -a "$dev" >/dev/null 2>&1 || true
  fi

  if [[ -x /sbin/kpartx ]]; then
    kpartx_bin=/sbin/kpartx
  elif [[ -x /usr/sbin/kpartx ]]; then
    kpartx_bin=/usr/sbin/kpartx
  fi
  if [[ -n "$kpartx_bin" ]]; then
    "$kpartx_bin" -a "$dev" >/dev/null 2>&1 || true
    local kp_name
    kp_name=$("$kpartx_bin" -l "$dev" 2>/dev/null | awk 'NF{print $1; exit}')
    if [[ -n "$kp_name" && -e "/dev/mapper/$kp_name" ]]; then
      echo "/dev/mapper/$kp_name"
      return
    fi
  fi

  if [[ -x /sbin/udevadm ]]; then
    udevadm_bin=/sbin/udevadm
  elif [[ -x /usr/sbin/udevadm ]]; then
    udevadm_bin=/usr/sbin/udevadm
  fi
  if [[ -n "$udevadm_bin" ]]; then
    "$udevadm_bin" settle >/dev/null 2>&1 || true
  fi

  local base mapper_name
  base=$(basename "$dev")
  mapper_name="$base"
  if [[ "$dev" == /dev/*/* ]]; then
    local vg lv
    vg=$(basename "$(dirname "$dev")")
    lv=$(basename "$dev")
    mapper_name="${vg}-${lv}"
  fi

  local cand
  for cand in \
    "/dev/${base}p1" \
    "/dev/mapper/${mapper_name}p1" \
    "/dev/mapper/${base}p1" \
    "/dev/mapper/${mapper_name}1" \
    "/dev/mapper/${base}1"; do
    if [[ -e "$cand" ]]; then
      echo "$cand"
      return
    fi
  done

  if command -v lsblk >/dev/null 2>&1; then
    local name
    name=$(lsblk -n -o NAME,TYPE -r "$dev" 2>/dev/null | awk '$2=="part"{print $1; exit}')
    if [[ -n "$name" ]]; then
      if [[ -e "/dev/$name" ]]; then
        echo "/dev/$name"
        return
      fi
      if [[ -e "/dev/mapper/$name" ]]; then
        echo "/dev/mapper/$name"
        return
      fi
    fi
  fi
  echo "$dev"
}

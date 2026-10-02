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
  local factory
  if [[ -f "$SHADOW_CONF_DEFAULT" ]]; then
    cp "$SHADOW_CONF_DEFAULT" "$CONF_FILE_DEFAULT"
  elif [[ ! -f "$CONF_FILE_DEFAULT" ]] && factory=$(golden_conf); then
    cp "$factory" "$CONF_FILE_DEFAULT"
  fi
  ensure_gateway_home_in_conf "$CONF_FILE_DEFAULT"
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

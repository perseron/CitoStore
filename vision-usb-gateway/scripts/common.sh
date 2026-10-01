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
  if [[ -f "$SHADOW_CONF_DEFAULT" ]]; then
    cp "$SHADOW_CONF_DEFAULT" "$CONF_FILE_DEFAULT"
  elif [[ ! -f "$CONF_FILE_DEFAULT" && -f "$GATEWAY_HOME/conf/vision-gw.conf.example" ]]; then
    cp "$GATEWAY_HOME/conf/vision-gw.conf.example" "$CONF_FILE_DEFAULT"
  fi
  ensure_gateway_home_in_conf "$CONF_FILE_DEFAULT"
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

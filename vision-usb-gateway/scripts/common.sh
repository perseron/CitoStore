#!/usr/bin/env bash
set -euo pipefail

CONF_FILE_DEFAULT=/etc/vision-gw.conf

log() {
  echo "[$(date -Is)] $*" >&2
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
  fi
}

load_config() {
  local conf_file="${1:-$CONF_FILE_DEFAULT}"
  if [[ -f "$conf_file" ]]; then
    # shellcheck source=/dev/null
    source "$conf_file"
  else
    log "config not found: $conf_file"
  fi
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

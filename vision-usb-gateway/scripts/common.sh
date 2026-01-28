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
    sed -i "1 s#\\$# ${key_escaped}#" /boot/firmware/cmdline.txt
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

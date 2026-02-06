#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root

log "installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  lvm2 thin-provisioning-tools dosfstools \
  samba cifs-utils rsync wsdd kpartx \
  nvme-cli \
  python3 python3-venv python3-pip \
  util-linux \
  initramfs-tools

# Install overlayroot provider. Package name varies by distro.
if ! dpkg -s overlayroot >/dev/null 2>&1; then
  if ! apt-get install -y overlayroot; then
    apt-get install -y cloud-initramfs-tools
  fi
fi

if [[ ! -f /etc/vision-gw.conf ]]; then
  log "installing default config to /etc/vision-gw.conf"
  cp "$SCRIPT_DIR/../conf/vision-gw.conf.example" /etc/vision-gw.conf
fi

log "done"

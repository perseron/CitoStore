#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/common.sh"

require_root

BOOT_MOUNT=/boot/firmware
BOOT_WAS_RO=false
if mountpoint -q "$BOOT_MOUNT"; then
  opts=$(findmnt -no OPTIONS "$BOOT_MOUNT" 2>/dev/null || true)
  if echo ",$opts," | grep -q ",ro,"; then
    BOOT_WAS_RO=true
    log "remounting $BOOT_MOUNT read-write"
    mount -o remount,rw "$BOOT_MOUNT"
  fi
fi

cleanup_boot_mount() {
  if $BOOT_WAS_RO && mountpoint -q "$BOOT_MOUNT"; then
    log "remounting $BOOT_MOUNT read-only"
    mount -o remount,ro "$BOOT_MOUNT" || true
  fi
}
trap cleanup_boot_mount EXIT

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
  if apt-cache show overlayroot >/dev/null 2>&1; then
    apt-get install -y overlayroot
  elif apt-cache show cloud-initramfs-tools >/dev/null 2>&1; then
    apt-get install -y cloud-initramfs-tools
  else
    log "overlayroot provider package not found in repositories"
  fi
fi

if [[ ! -f /etc/vision-gw.conf ]]; then
  log "installing default config to /etc/vision-gw.conf"
  cp "$SCRIPT_DIR/../conf/vision-gw.conf.example" /etc/vision-gw.conf
fi

log "done"

#!/usr/bin/env bash
set -euo pipefail

require_root() { [[ $(id -u) -eq 0 ]] || { echo "must run as root" >&2; exit 1; }; }

require_root

WIPE=false
for arg in "$@"; do
  case "$arg" in
    --wipe|--i-know-what-im-doing) WIPE=true ;;
  esac
done

systemctl disable --now usb-gadget.service vision-sync.timer vision-monitor.timer vision-rotator.timer mirror-retention.timer >/dev/null 2>&1 || true
systemctl disable --now mnt-nas.automount nas-sync.timer >/dev/null 2>&1 || true

if $WIPE; then
  rm -f /etc/vision-gw.conf /etc/vision-gw.env /etc/vision-nas.creds
  rm -f /etc/systemd/system/usb-gadget.service
  rm -f /etc/systemd/system/vision-*.service /etc/systemd/system/vision-*.timer
  rm -f /etc/systemd/system/mirror-retention.*
  rm -f /etc/systemd/system/offline-maint@.service
  rm -f /etc/systemd/system/mnt-nas.mount /etc/systemd/system/mnt-nas.automount
  systemctl daemon-reload
fi

echo "uninstall complete"
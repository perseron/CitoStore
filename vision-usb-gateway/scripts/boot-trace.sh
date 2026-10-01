#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

# Append a boot-phase breadcrumb to the FAT boot partition, which is readable
# from Windows (rpiboot) even when the unit never comes up — so a dead boot
# still tells how far it got. The journal cannot do this: it is volatile, and
# an early hang leaves it empty.
BOOT_MOUNT=/boot/firmware
# In a subfolder, not the FAT root: the root directory holds config.txt and
# the kernel, and this file is rewritten (tmp + rename) up to three times per
# boot — including the earliest seconds, when a weak supply browns out. A
# power cut mid-update then risks the directory the unit boots from.
TRACE_DIR="$BOOT_MOUNT/citostore"
TRACE="$TRACE_DIR/boot-trace.txt"
MAX_LINES=60
phase="${1:-mark}"

mountpoint -q "$BOOT_MOUNT" || exit 0

was_ro=false
if findmnt -no OPTIONS "$BOOT_MOUNT" | tr ',' '\n' | grep -qx ro; then
  was_ro=true
  mount -o remount,rw "$BOOT_MOUNT" 2>/dev/null || exit 0
fi

{
  mkdir -p "$TRACE_DIR"
  # One-time move of the file older builds kept in the root.
  if [[ -f "$BOOT_MOUNT/boot-trace.txt" ]]; then mv -f "$BOOT_MOUNT/boot-trace.txt" "$TRACE"; fi
  build=$(grep -m1 '^CITOSTORE_BUILD_SHA=' /etc/citostore-build 2>/dev/null | cut -d= -f2 || true)
  up=$(awk '{print int($1)}' /proc/uptime)
  extra=""
  if [[ "$phase" == "boot-complete" ]]; then
    extra=" failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
  fi
  printf '%s up=%ss build=%s %s%s\n' "$(date -Is 2>/dev/null || date)" "$up" "${build:-?}" "$phase" "$extra" >> "$TRACE"
  tail -n "$MAX_LINES" "$TRACE" > "$TRACE.tmp" && mv -f "$TRACE.tmp" "$TRACE"
} 2>/dev/null || true

sync
if [[ "$was_ro" == "true" ]]; then
  mount -o remount,ro "$BOOT_MOUNT" 2>/dev/null || true
fi

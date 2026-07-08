#!/usr/bin/env bash
set -euo pipefail

# Export the migratable configuration + state from a running CitoStore device
# into a single tarball. Run this on the OLD device. Nothing here is
# hardware-specific except a few keys in vision-gw.conf that the import step
# flags for review.
#
# Usage:
#   sudo scripts/export-config-bundle.sh [/path/to/output.tgz]
# Default output: /tmp/citostore-config-<hostname>-<date>.tgz

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

STATE_DIR=/srv/vision_mirror/.state
OUT="${1:-/tmp/citostore-config-$(hostname)-$(date +%Y%m%d_%H%M%S).tgz}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/state" "$STAGE/etc" "$STAGE/network"

# 1) Authoritative config. Prefer the WebUI shadow copy, fall back to /etc.
if [[ -f "$STATE_DIR/vision-gw.conf" ]]; then
  cp "$STATE_DIR/vision-gw.conf" "$STAGE/etc/vision-gw.conf"
elif [[ -f /etc/vision-gw.conf ]]; then
  cp /etc/vision-gw.conf "$STAGE/etc/vision-gw.conf"
fi

# 2) WebUI identity + secrets (optional; can be re-set instead).
for f in webui.passwd webui.secret vision-nas.creds; do
  [[ -f "$STATE_DIR/$f" ]] && cp "$STATE_DIR/$f" "$STAGE/state/$f"
done

# 3) NAS creds in /etc too (in case shadow is absent).
[[ -f /etc/vision-nas.creds ]] && cp /etc/vision-nas.creds "$STAGE/etc/vision-nas.creds"

# 4) AOI persist folder (host settings preserved across USB rotations).
if [[ -d "$STATE_DIR/aoi_settings" ]]; then
  cp -a "$STATE_DIR/aoi_settings" "$STAGE/state/aoi_settings"
fi

# 5) Network: the recorded intent plus the live NetworkManager profiles.
[[ -f "$STATE_DIR/network.json" ]] && cp "$STATE_DIR/network.json" "$STAGE/network/network.json"
if command -v nmcli >/dev/null 2>&1; then
  nmcli -t -f NAME connection show 2>/dev/null | while read -r name; do
    [[ -z "$name" ]] && continue
    safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
    nmcli connection export "$name" > "$STAGE/network/$safe.nmconnection" 2>/dev/null || true
  done
fi

# 6) Samba password DB (so the existing SMB user/password carries over).
if [[ -f /var/lib/samba/private/passdb.tdb ]]; then
  mkdir -p "$STAGE/samba"
  cp /var/lib/samba/private/passdb.tdb "$STAGE/samba/passdb.tdb"
fi

# Provenance for the import step to sanity-check against.
{
  echo "exported_from=$(hostname)"
  echo "exported_at=$(date -Is)"
  echo "kernel=$(uname -r)"
  echo "model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
} > "$STAGE/MANIFEST.txt"

tar -czf "$OUT" -C "$STAGE" .
chmod 0600 "$OUT"
log "config bundle written: $OUT"
echo "$OUT"

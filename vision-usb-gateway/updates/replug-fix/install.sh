#!/usr/bin/env bash
set -euo pipefail

# Update package: a re-plugged Ethernet cable decides network vs direct again
# (commit 676108b), for units flashed with bb27fc1. Run by apply-update.sh from
# the unpacked package: once on upload (vision-update.service) and, in overlay
# mode, on every boot (vision-update-reapply) — the fix lives in the RAM layer,
# so it must be put back each boot. Idempotent.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATEWAY_HOME=${GATEWAY_HOME:-/opt/CitoStore/vision-usb-gateway}
BUILD_FILE=${CITOSTORE_BUILD_FILE:-/etc/citostore-build}

# Only onto the code this was made against: the files replace whole scripts,
# and on an older/newer unit that could undo other fixes. Refusing leaves the
# unit untouched and shows up as "failed" in the WebUI update history.
build=$(sed -n 's/^CITOSTORE_BUILD_SHA=//p' "$BUILD_FILE" 2>/dev/null | head -1)
compatible=$(sed -n 's/.*"compatible_builds": *\[\([^]]*\)\].*/\1/p' "$HERE/manifest.json" | tr -d '"' | tr ',' ' ')
if [[ " $compatible " != *" ${build:-none} "* ]]; then
  echo "this package is for builds [${compatible# }]; this unit is '${build:-unknown}' — nothing changed" >&2
  exit 1
fi

while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  src="$HERE/files/$rel"
  if [[ "$rel" == *.sh ]]; then
    bash -n "$src" || { echo "refusing $rel: syntax check failed" >&2; exit 1; }
    install -m 0755 "$src" "$GATEWAY_HOME/$rel"
  else
    install -m 0644 "$src" "$GATEWAY_HOME/$rel"
  fi
  echo "installed $rel"
done < "$HERE/files.txt"

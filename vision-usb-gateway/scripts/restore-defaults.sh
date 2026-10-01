#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${MIRROR_MOUNT:=/srv/vision_mirror}"
STATE_DIR="$MIRROR_MOUNT/.state"

usage() {
  cat <<'EOF'
Usage:
  restore-defaults.sh --i-know-what-im-doing

Restores THIS UNIT's factory configuration — the golden image's own config
(/etc/citostore-seed/vision-gw.conf, or the overlay's read-only /etc), not the
generic conf/vision-gw.conf.example — into the NVMe shadow config, and applies
it. Data volumes, passwords and the network setting are NOT modified.
EOF
}

CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --i-know-what-im-doing)
      CONFIRM=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$CONFIRM" != "true" ]]; then
  echo "Refusing to run without --i-know-what-im-doing" >&2
  exit 1
fi

# The generic example is NOT this unit's default: it has 100G USB LVs (more than
# the 64G pool holds), another NetBIOS name and workgroup, a 2 min sync cadence
# instead of the tuned one, no soft-switch settings... Restoring it silently
# de-tuned the unit.
if ! DEFAULT_CONF=$(golden_conf); then
  echo "no factory configuration found; nothing changed" >&2
  exit 1
fi
# The shadow on the NVMe is the copy that survives a reboot under the overlay.
if ! mountpoint -q "$MIRROR_MOUNT"; then
  echo "NVMe mirror not mounted; nothing changed" >&2
  exit 1
fi
log "restoring the factory configuration from $DEFAULT_CONF"
mkdir -p "$STATE_DIR"
tmp=$(mktemp "$STATE_DIR/vision-gw.conf.XXXXXX")
cp "$DEFAULT_CONF" "$tmp"
ensure_gateway_home_in_conf "$tmp"
chmod 0644 "$tmp"
sync "$tmp" 2>/dev/null || sync
mv -f "$tmp" "$STATE_DIR/vision-gw.conf"

# Apply now: copying the files alone left the unit running the old settings
# until a reboot, while the WebUI already showed the defaults.
if ! /bin/bash "$SCRIPT_DIR/apply-shadow-config.sh"; then
  echo "defaults written, but applying them failed (see the log)" >&2
  exit 1
fi
echo "Defaults restored and applied."

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

# Every step runs even if an earlier one fails, and the script fails at the end
# if any did. Before, one failing step (60_nas: its units could never load)
# aborted the rest under set -e — ingest password, mDNS and mirror FTP were then
# never re-applied on any boot — while 70/75/80 had "|| true", so a failure
# there was reported to the WebUI as success.
failed=()
step() {  # <name> <command...>
  local name=$1; shift
  if ! "$@"; then
    failed+=("$name")
    log "apply-shadow-config: step '$name' FAILED"
  fi
}

# Capture the WebUI's own bind/port BEFORE update-config overwrites the live
# config, so we only bounce the WebUI when its listener actually changed (see
# the deferred restart at the end).
webui_before=$(grep -hE '^(WEBUI_BIND|WEBUI_PORT)=' /etc/vision-gw.conf 2>/dev/null | sort | tr '\n' ' ' || true)

# update-config.sh restores /etc/vision-gw.conf (+ NAS creds) from the shadow,
# re-asserts GATEWAY_HOME, and writes /etc/vision-gw.env. Everything below reads
# the populated /etc/vision-gw.conf, so it must run first.
step config "$GATEWAY_HOME/scripts/update-config.sh"
step samba "$GATEWAY_HOME/install/50_configure_samba.sh"

if grep -q '^NAS_ENABLED=true' /etc/vision-gw.conf 2>/dev/null; then
  step nas "$GATEWAY_HOME/install/60_configure_nas_optional.sh"
else
  step nas-off "$GATEWAY_HOME/install/60_configure_nas_optional.sh" --disable
fi

# eth1 + FTP/SFTP ingest (overlay-safe: re-applied from config on every boot).
step ingest "$GATEWAY_HOME/install/70_configure_ingest.sh"

# mDNS (.local) name advertising for router-free / field access.
step mdns "$GATEWAY_HOME/install/75_configure_mdns.sh"

# Read-only FTP export of the mirror on eth0 (alternative to SMB).
step mirror-ftp "$GATEWAY_HOME/install/80_configure_mirror_ftp.sh"

# Restart the WebUI only if its own bind/port changed, and do it out-of-band
# (a transient timer 2s out) so a WebUI-triggered apply can still deliver its
# HTTP response before we drop its listener. A same-cgroup restart here would
# kill the very request that invoked apply. Fall back to a direct restart where
# systemd-run is unavailable.
webui_after=$(grep -hE '^(WEBUI_BIND|WEBUI_PORT)=' /etc/vision-gw.conf 2>/dev/null | sort | tr '\n' ' ' || true)
if [[ "$webui_before" != "$webui_after" ]]; then
  log "WebUI bind/port changed; scheduling out-of-band restart"
  systemd-run --quiet --collect --on-active=2 --timer-property=AccuracySec=100ms systemctl restart vision-webui.service || systemctl restart vision-webui.service || true
fi

# last-good = a config that was actually applied without errors; health-check
# rolls back to it if the shadow later fails its validity check. (It used to be
# overwritten with the new config BEFORE applying it, so a bad config became
# its own fallback.)
if ((${#failed[@]})); then
  log "apply-shadow-config: finished with failures: ${failed[*]}"
  exit 1
fi
if [[ -f "$SHADOW_CONF_DEFAULT" ]]; then
  cp "$SHADOW_CONF_DEFAULT" /srv/vision_mirror/.state/vision-gw.conf.last-good
fi

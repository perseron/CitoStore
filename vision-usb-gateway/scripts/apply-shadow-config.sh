#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

require_root

# Snapshot the current shadow config as last-good before applying; health-check
# rolls back to this if the live config later fails its validity check.
if [[ -f "$SHADOW_CONF_DEFAULT" ]]; then
  cp "$SHADOW_CONF_DEFAULT" /srv/vision_mirror/.state/vision-gw.conf.last-good
fi

# Capture the WebUI's own bind/port BEFORE update-config overwrites the live
# config, so we only bounce the WebUI when its listener actually changed (see
# the deferred restart at the end).
webui_before=$(grep -hE '^(WEBUI_BIND|WEBUI_PORT)=' /etc/vision-gw.conf 2>/dev/null | sort | tr '\n' ' ' || true)

# update-config.sh restores /etc/vision-gw.conf (+ NAS creds) from the shadow,
# re-asserts GATEWAY_HOME, and writes /etc/vision-gw.env. Everything below reads
# the populated /etc/vision-gw.conf, so it must run first.
"$GATEWAY_HOME/scripts/update-config.sh"
"$GATEWAY_HOME/install/50_configure_samba.sh"

if grep -q '^NAS_ENABLED=true' /etc/vision-gw.conf 2>/dev/null; then
  "$GATEWAY_HOME/install/60_configure_nas_optional.sh"
else
  systemctl disable --now mnt-nas.automount nas-sync.timer || true
fi

# eth1 + FTP/SFTP ingest (overlay-safe: re-applied from config on every boot).
"$GATEWAY_HOME/install/70_configure_ingest.sh" || true

# mDNS (.local) name advertising for router-free / field access.
"$GATEWAY_HOME/install/75_configure_mdns.sh" || true

# Read-only FTP export of the mirror on eth0 (alternative to SMB).
"$GATEWAY_HOME/install/80_configure_mirror_ftp.sh" || true

# Restart the WebUI only if its own bind/port changed, and do it out-of-band
# (a transient timer 2s out) so a WebUI-triggered apply can still deliver its
# HTTP response before we drop its listener. A same-cgroup restart here would
# kill the very request that invoked apply. Fall back to a direct restart where
# systemd-run is unavailable.
webui_after=$(grep -hE '^(WEBUI_BIND|WEBUI_PORT)=' /etc/vision-gw.conf 2>/dev/null | sort | tr '\n' ' ' || true)
if [[ "$webui_before" != "$webui_after" ]]; then
  log "WebUI bind/port changed; scheduling out-of-band restart"
  systemd-run --quiet --collect --on-active=2 systemctl restart vision-webui.service || systemctl restart vision-webui.service || true
fi

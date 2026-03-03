# TODO

## P0 - Critical (unattended reliability)
- RTC time setup (done)
- Examine how the NAS credentials file (`/etc/vision-nas.creds`) behaves in overlay mode; ensure credentials persist and are applied correctly on boot. (done)
- Add "last good config" rollback for shadow config if apply fails (done)
- Add health-check status endpoint + WebUI banner (safe/degraded) (done)
- Add snapshot cleanup job if `usb_sync_snap` exists after failed sync (done)
- Add log rotation/cleanup service + timer for overlay mode to cap log growth (journald + app logs) during long runtimes. (done)

## P1 - High (resilience + observability)
- Add boot-time log persistence under `/srv/vision_mirror/.state/logs` with rotation (done)
- Add watchdog enablement + systemd watchdog kick for long-running services (done)
- Add explicit USB LV health report (FAT32 fsck summary) surfaced in WebUI (done)
- Add NAS offline queueing + retry backoff summary in WebUI (done)
- Add time sync policy (RTC + NTP fallback, display status in WebUI) (done)
- Add web-based update system: upload a compressed update package with install script and apply safely (done)
- Add NVMe pressure safeguards: keep retention decoupled from sync, but add sync-side mirror free-space guard and optional non-blocking retention trigger when mirror usage is high. (done)

## P2 - Medium (operations)
- Add "maintenance mode" switch in WebUI (disable rotation/sync safely) (done)
- Add UPS/power-loss detection hooks (if hardware supports it)
- Assess filename-append behavior: only append on name collisions vs always append; evaluate resource cost of collision checks. (done)

## Completed in recent batch
- Login rate limiting (5 attempts per 15 min window per IP)
- Missing WebUI config fields: SMB_BIND_INTERFACE, WEBUI_BIND, WEBUI_PORT
- Manual sync trigger button
- Config export/import
- Health check periodic refresh (monitor writes health JSON)

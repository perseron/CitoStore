# TODO

## P0 - Critical (unattended reliability)
- RTC time setup (in progress)
- Examine how the NAS credentials file (`/etc/vision-nas.creds`) behaves in overlay mode; ensure credentials persist and are applied correctly on boot.
- Add “last good config” rollback for shadow config if apply fails
- Add health-check status endpoint + WebUI banner (safe/degraded)
- Add snapshot cleanup job if `usb_sync_snap` exists after failed sync

## P1 - High (resilience + observability)
- Add boot-time log persistence under `/srv/vision_mirror/.state/logs` with rotation
- Add watchdog enablement + systemd watchdog kick for long-running services
- Add explicit USB LV health report (FAT32 fsck summary) surfaced in WebUI
- Add NAS offline queueing + retry backoff summary in WebUI
- Add time sync policy (RTC + NTP fallback, display status in WebUI)

## P2 - Medium (operations)
- Add “maintenance mode” switch in WebUI (disable rotation/sync safely)
- Add UPS/power-loss detection hooks (if hardware supports it)

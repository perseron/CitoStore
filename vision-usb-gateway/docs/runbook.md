# Runbook

Prereqs
- Raspberry Pi OS Lite 64-bit (Bookworm) on eMMC
- NVMe installed and visible as `/dev/nvme0n1` (configurable)
- Network on eth0 for SMB and optional NAS

Install
1) Copy config and edit
   - `cp conf/vision-gw.conf.example /etc/vision-gw.conf`
2) Install packages and base config
   - `sudo install/00_prereqs.sh`
3) Enable USB OTG
   - `sudo install/10_configure_otg.sh`
4) Enable read-only overlay
   - `sudo install/20_enable_readonly_overlay.sh`
5) NVMe LVM setup (safe by default)
   - `sudo install/30_setup_nvme_lvm.sh`
   - Add `--wipe` only if you want partition/LVM creation
6) Install and enable services
   - `sudo install/40_install_services.sh`
   - `vision-gw-config.service` applies `/etc/vision-gw.conf` to systemd on boot
7) Configure Samba
   - `sudo install/50_configure_samba.sh`
   - NetBIOS name + WSDD use `NETBIOS_NAME` and `SMB_WORKGROUP` in `/etc/vision-gw.conf`
8) Optional NAS
   - `sudo install/60_configure_nas_optional.sh`
   - Creates `/etc/vision-nas.creds` if missing (mode `0600`).
   - Contents format:
     - `username=<nas_user>`
     - `password=<nas_password>`
     - `domain=<nas_domain>` (optional)
9) Reboot
   - `sudo reboot`

Validation checklist
- USB gadget enumerates on the vision host
- `/srv/vision_mirror` mounted from `vg0/mirror`
- `systemctl status usb-gadget.service vision-sync.service`
- SMB share reachable read-only
- Active USB LV persisted at `/srv/vision_mirror/.state/vision-usb-active`

Web UI (minimal config + maintenance)
- Service: `vision-webui.service`
- Default bind/port: `WEBUI_BIND=0.0.0.0`, `WEBUI_PORT=80`
- Access from Windows browser: `http://<device-ip>/`
- Minimal required config for Web UI: `WEBUI_BIND`, `WEBUI_PORT`, `SMB_BIND_INTERFACE`.
- First login prompts for a Web UI password (stored hashed in `/srv/vision_mirror/.state/webui.passwd`).
- The UI edits a shadow config at `/srv/vision_mirror/.state/vision-gw.conf`.
- Apply config triggers `apply-shadow-config.sh`, which:
  - Copies the shadow config to `/etc/vision-gw.conf`
  - Updates systemd overrides (`vision-sync.timer`)
  - Reconfigures Samba + WSDD
  - Enables/disables NAS units based on `NAS_ENABLED`
- Network settings are persisted in `/srv/vision_mirror/.state/network.json` and applied on boot by `vision-gw-network.service`.
- Destructive actions require typed confirmation in the UI.
- Smoke check:
  - `systemctl status vision-webui.service`
  - `curl -I http://127.0.0.1/` (expect 200/303)

Boot-time auto-recovery
- `vision-gw-health.service` runs before core services and auto-recovers common issues:
  - Restores missing shadow config from defaults.
  - Fixes missing `GATEWAY_HOME` in shadow config.
  - Removes stale sync snapshot LVs.
  - Validates active USB LV pointer; selects a valid LV if missing.
  - Validates `vision.db` and moves it aside if corrupted.
  - Runs `fsck -p` on the mirror LV if it is not mounted.
  - Runs `fsck.fat -a` on inactive USB LVs to repair FAT32 inconsistencies.

Rotation + maintenance
- Monitor state: `/run/vision-rotate.state`
- Offline processing logs: `journalctl -u offline-maint@usb_0`
- Sync timer tuning (in `/etc/vision-gw.conf`):
  - `SYNC_ONBOOT_SEC`, `SYNC_ONACTIVE_SEC`, `SYNC_INTERVAL_SEC`
- USB persist (AOI settings):
  - Folder on USB LV: `USB_PERSIST_DIR` (default `aoi_settings`)
  - Backing store: `USB_PERSIST_BACKING` (default `/srv/vision_mirror/.state/aoi_settings`)
  - Manifest: `/srv/vision_mirror/.state/usb_persist.manifest`
  - Sync behavior:
    - Snapshot sync updates backing + pre-seeds the next LV when contents change.
    - Rotation verifies the next LV and auto-repairs if it drifts.
  - Optional duration file: `USB_PERSIST_DURATION_FILE` (default `/srv/vision_mirror/aoi_settings_duration.txt`)
- Maintenance (overlay off):
  - `sudo install/21_disable_readonly_overlay.sh`
  - The script auto-remounts `/boot/firmware` read-write if needed, then returns it to read-only.
  - Use `--boot-rw` to make `/boot/firmware` writable in `fstab`.
  - Reboot, perform changes
  - `sudo install/20_enable_readonly_overlay.sh`
  - The script auto-remounts `/boot/firmware` read-write if needed, then returns it to read-only.
  - Use `--boot-ro` to force `/boot/firmware` read-only in `fstab`.
  - Reboot

Operational flow (precise)
1) USB gadget exposes the active FAT32 LV to the host; the CM5 never mounts the active LV.
2) `vision-sync.timer` triggers `vision-sync.service` on boot and on schedule.
3) `vision-sync` creates a thin snapshot of the active LV, mounts it read-only, and scans files.
4) A file is considered stable after `STABLE_SCAN_REQUIRED` consecutive scans with identical size+mtime.
5) Stable files are copied into `raw/` preserving the original folder structure, then hardlinked into `bydate/YYYY/MM/DD/`.
6) `vision-monitor` checks LV usage + thinpool metadata; if thresholds are exceeded it writes `/run/vision-rotate.state`.
7) `vision-rotator` switches the USB gadget to the next LV (within the configured window unless critical).
8) After switching, `offline-maint@<old_lv>` runs: filesystem check, offline sync, discard, reformat, and persist-folder handling.
9) USB persist folder changes are mirrored to `USB_PERSIST_BACKING`; the next LV is pre-seeded and verified.
10) Mirror retention removes the oldest entries when disk usage exceeds thresholds.

Operational flow (detailed, step-by-step)
1) Boot + mounts
   - NVMe mirror LV mounts at `/srv/vision_mirror` (ext4, RW).
   - Persistent state (SQLite, active LV pointer, persist manifest) lives under `/srv/vision_mirror/.state`.
2) USB gadget exposure
   - `usb-gadget.service` binds exactly one FAT32 LV to the USB gadget LUN.
   - The host sees only the active LV; the CM5 never mounts the active LV.
   - The previously active LV is restored from `/srv/vision_mirror/.state/vision-usb-active` on boot.
3) Sync scheduling
   - `vision-sync.timer` drives the sync cadence:
     - `SYNC_ONBOOT_SEC`: first run after boot.
     - `SYNC_ONACTIVE_SEC`: run after timer activation.
     - `SYNC_INTERVAL_SEC`: subsequent runs after a successful run.
4) Snapshot + scan
   - `vision-sync` creates a thin snapshot (`SYNC_SNAPSHOT_NAME`) of the active LV.
   - Mounts the snapshot read-only at `SYNC_MOUNT`.
   - Enumerates files and skips system folders like `System Volume Information` and `$RECYCLE.BIN`.
5) Stability gating
   - A file must be stable across `STABLE_SCAN_REQUIRED` consecutive scans (size+mtime unchanged).
   - With `STABLE_SCAN_REQUIRED=2`, a new file typically syncs on the second run.
6) Copy + indexing
   - Stable files are copied into `raw/` preserving original folder structure.
   - Copies are atomic (temp file + rename); content hash is used to de-duplicate.
   - A hardlink is created in `bydate/YYYY/MM/DD/` pointing to the `raw/` file.
7) Persist folder handling
   - If `USB_PERSIST_DIR` exists, a manifest is computed and compared to the last stored hash.
   - When changed, it is synced to `USB_PERSIST_BACKING`.
   - The next LV is pre-seeded; rotation verifies and auto-repairs if it drifts.
8) Rotation decision
   - `vision-monitor` checks active LV usage (`THRESH_HI`/`THRESH_CRIT`) and thinpool metadata (`META_HI`/`META_CRIT`).
   - Writes `/run/vision-rotate.state` with `state=ok|rotate_pending|panic`.
9) Rotation execution
   - `vision-rotator` switches LVs inside the configured window unless in `panic`.
   - Updates the persisted active LV pointer.
10) Offline maintenance
    - `offline-maint@<old_lv>` performs fsck, offline sync, discard, reformat, and persist-folder restore.
11) Retention
    - `mirror-retention` deletes the oldest entry (raw + bydate link) when usage exceeds `RETENTION_HI` until `RETENTION_LO`.

Config parameter reference (key meanings)
Storage + LVM
- `NVME_DEVICE`: Block device used for LVM (e.g., `/dev/nvme0n1`).
- `LVM_VG`: Volume group name hosting mirror + thinpool (default `vg0`).
- `MIRROR_LV`: LV name for the mirror filesystem (default `mirror`).
- `MIRROR_MOUNT`: Mount path for the mirror (default `/srv/vision_mirror`).
- `MIRROR_SIZE`: Size of the mirror LV (e.g., `300G`).
- `THINPOOL_LV`: Thinpool LV name (default `usbpool`).
- `THINPOOL_SIZE`: Thinpool size (e.g., `650G`).
- `THINPOOL_META_SIZE`: Thinpool metadata LV size (e.g., `8G`).
- `USB_LVS`: Array of thin LVs exported to the host (rotation ring).
- `USB_LABEL`: FAT32 volume label for the USB LVs.
- `USB_LV_SIZE`: Size of each USB LV.
- `USB_ACTIVE_PERSIST`: Persistent file storing active LV device path across reboots.

USB gadget
- `USB_GADGET_NAME`: ConfigFS gadget name (directory under `/sys/kernel/config/usb_gadget`).
- `USB_VENDOR_ID`, `USB_PRODUCT_ID`: USB VID/PID.
- `USB_MANUFACTURER`, `USB_PRODUCT`: USB descriptor strings.
- `USB_SERIAL`: USB serial string.
- `USB_CONFIG`: USB configuration string.
- `USB_MAX_POWER`: Max power (mA) reported to host.

Snapshot sync
- `SYNC_SNAPSHOT_NAME`: LV snapshot name used for sync (default `usb_sync_snap`).
- `SYNC_MOUNT`: Mount point for the snapshot (read-only).
- `SYNC_ONBOOT_SEC`: Delay after boot before first sync run (systemd time format).
- `SYNC_ONACTIVE_SEC`: Delay after timer activation before next run (systemd time format).
- `SYNC_INTERVAL_SEC`: Interval between runs after a successful run (systemd time format).
- `SYNC_CHANGE_DETECT`: If `true`, uses a two-phase manifest gate. When changes are detected, copy runs every cycle. When unchanged for `SYNC_CHANGE_RESUME_SCANS` consecutive runs, the copy phase is skipped; when changes resume, copy runs again.
- `SYNC_MANIFEST_FILE`: Path to the stored manifest hash used for change detection.
- `SYNC_CHANGE_RESUME_SCANS`: Number of consecutive unchanged runs required before skipping copy again.
- `STABLE_SCAN_REQUIRED`: Number of consecutive scans required before a file is copied. If set to `2`, a new file typically appears on the second run after creation.
- `MAX_FILE_SIZE_BYTES`: Files equal/above this size are skipped (FAT32 4GiB limit default).
- `COPY_CHUNK_BYTES`: Copy chunk size for atomic copy.

USB persist (AOI settings)
- `USB_PERSIST_DIR`: Folder name on the USB LV to preserve (e.g., `aoi_settings`).
- `USB_PERSIST_BACKING`: Backing store on NVMe used to preserve the folder across rotation.
- `USB_PERSIST_DURATION_FILE`: Optional file to write persist copy durations.

Rotation thresholds
- `THRESH_HI`/`THRESH_CRIT`: Percent usage of the active USB LV that triggers rotate-pending / panic.
- `META_HI`/`META_CRIT`: Percent metadata usage of the thinpool that triggers rotate-pending / panic.
- `SWITCH_WINDOW_START`/`SWITCH_WINDOW_END`: Allowed window for non-critical rotation.

Mirror retention
- `RETENTION_HI`: Percent usage threshold to start deleting oldest mirror entries.
- `RETENTION_LO`: Percent usage target to stop deleting.

NAS optional
- `NAS_ENABLED`: Enable NAS sync service.
- `NAS_MOUNT`: Local mount for NAS.
- `NAS_REMOTE`: Remote NAS path.
- `NAS_CREDENTIALS`: Credentials file for NAS mount.
- `NAS_RSYNC_OPTS`: rsync options for NAS sync.
- `NAS_RETRY_MAX`/`NAS_RETRY_BACKOFF`: Retry behavior for NAS sync.

RTC
- `RTC_ENABLED`: Enable RTC sync on boot and periodically.
- `RTC_DEVICE`: RTC device (default `/dev/rtc0`).
- `RTC_UTC`: `true` for UTC, `false` for localtime.
- `RTC_SYNC_INTERVAL`: Periodic sync interval (systemd time format).
- Boot sync runs only if NTP is not synchronized.
- Web UI supports manual time set as a fallback (writes system time and updates RTC).

Samba + discovery
- `SMB_BIND_INTERFACE`: Network interface Samba/WSDD bind to.
- `SMB_USER`: Samba user for read-only access.
- `NETBIOS_NAME`: NetBIOS name advertised by Samba/WSDD.
- `SMB_WORKGROUP`: Windows workgroup name.

Web UI
- `WEBUI_BIND`: IP to bind the Web UI (default `0.0.0.0`).
- `WEBUI_PORT`: Port for the Web UI (default `80`).

Windows host setup
- See `docs/windows-install.md` for a Windows-first, empty system install path.

Maintenance utilities
- Resize USB LVs:
  - `sudo /opt/vision-usb-gateway/scripts/resize-usb-lvs.sh --size 4G --force`
- Resize USB LVs + update config:
  - `sudo /opt/vision-usb-gateway/scripts/resize-usb-lvs.sh --size 4G --force --update-config`
- Wipe all data (mirror + USB LVs + sync state DB):
  - `sudo /opt/vision-usb-gateway/scripts/wipe-all-data.sh --i-know-what-im-doing --force-umount`
- Rebalance storage from config (destructive):
  - `sudo /opt/vision-usb-gateway/scripts/rebalance-storage.sh --i-know-what-im-doing --update-config`
  - Add `--force-umount` if the mirror is busy.

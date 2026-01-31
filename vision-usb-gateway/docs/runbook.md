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
7) Configure Samba
   - `sudo install/50_configure_samba.sh`
   - NetBIOS name + WSDD use `NETBIOS_NAME` and `SMB_WORKGROUP` in `/etc/vision-gw.conf`
8) Optional NAS
   - `sudo install/60_configure_nas_optional.sh`
9) Reboot
   - `sudo reboot`

Validation checklist
- USB gadget enumerates on the vision host
- `/srv/vision_mirror` mounted from `vg0/mirror`
- `systemctl status usb-gadget.service vision-sync.service`
- SMB share reachable read-only
- Active USB LV persisted at `/srv/vision_mirror/.state/vision-usb-active`

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
  - Reboot, perform changes
  - `sudo install/20_enable_readonly_overlay.sh`
  - Reboot

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

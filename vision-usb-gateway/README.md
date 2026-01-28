# Vision USB Gateway (CM5)

This repo provisions a Raspberry Pi CM5 (non-wireless, 2GB RAM, 16GB eMMC) as a USB Mass Storage gadget for a vision host while mirroring images to NVMe and SMB.

Quick start (on the CM5):

1) Copy and edit config
   - `cp conf/vision-gw.conf.example /etc/vision-gw.conf`
   - Update device paths, USB LV count, gadget IDs, thresholds, and NAS settings
2) Run install scripts in order
   - `sudo install/00_prereqs.sh`
   - `sudo install/10_configure_otg.sh`
   - `sudo install/20_enable_readonly_overlay.sh`
   - `sudo install/30_setup_nvme_lvm.sh` (no destructive actions unless `--wipe`)
   - `sudo install/40_install_services.sh`
   - `sudo install/50_configure_samba.sh`
   - Optional NAS: `sudo install/60_configure_nas_optional.sh`
3) Reboot and verify
   - `sudo reboot`
   - `systemctl status usb-gadget.service`
   - `systemctl status vision-sync.service`

Safety warnings
- Destructive storage operations only run with `--wipe` or `--i-know-what-im-doing`.
- The active host-written FAT32 LV is NEVER mounted by the Pi. Only snapshots or offline LVs are mounted.
- Persistent state lives at `/srv/vision_mirror/.state` on NVMe.

Docs
- Architecture: `docs/architecture.md`
- Runbook: `docs/runbook.md`
- Windows install: `docs/windows-install.md`
- Read-only maintenance: `docs/maintenance-readonly.md`
- Troubleshooting: `docs/troubleshooting.md`

Make targets
- `make lint` (ruff)
- `make test` (pytest)

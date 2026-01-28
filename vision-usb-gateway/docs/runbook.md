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
8) Optional NAS
   - `sudo install/60_configure_nas_optional.sh`
9) Reboot
   - `sudo reboot`

Validation checklist
- USB gadget enumerates on the vision host
- `/srv/vision_mirror` mounted from `vg0/mirror`
- `systemctl status usb-gadget.service vision-sync.service`
- SMB share reachable read-only

Rotation + maintenance
- Monitor state: `/run/vision-rotate.state`
- Offline processing logs: `journalctl -u offline-maint@usb_0`

Windows host setup
- See `docs/windows-install.md` for a Windows-first, empty system install path.

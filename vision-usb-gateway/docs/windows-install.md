# Windows Host Installation (Empty System)

This is a precise, end-to-end installation guide for a **completely empty** CM5 system using a **Windows host**.

## 1) Prepare the OS image on Windows
1. Download **Raspberry Pi OS Lite 64-bit (Bookworm)**.
2. Install **Raspberry Pi Imager** on Windows.
3. Put the CM5 carrier into **eMMC flash mode** (per carrier docs).
4. In Raspberry Pi Imager:
   - OS: *Raspberry Pi OS Lite (64-bit)*
   - Storage: CM5 eMMC
   - Set **hostname**, **username**, **password**
   - Enable **SSH** (password auth OK for first boot)
   - Wi-Fi: configure only if you will use Wi-Fi for initial setup
5. Click **Write**, wait for completion, and safely eject.

## 2) Boot the CM5 and connect via SSH
1. Install NVMe in the CM5 carrier.
2. Power on the CM5.
3. Connect Ethernet to your network (recommended).
4. Find the CM5 IP address (router DHCP list or `arp -a` on Windows).
5. SSH in:
   - `ssh <user>@<ip>`

## 3) Clone the repo on the CM5
On the CM5:
```
sudo apt-get update -y
sudo apt-get install -y git
sudo git clone <your_repo_url> /opt/vision-usb-gateway
cd /opt/vision-usb-gateway
```

## 4) Copy and edit config
```
sudo cp conf/vision-gw.conf.example /etc/vision-gw.conf
sudo nano /etc/vision-gw.conf
```
Minimum edits:
- `USB_LVS=(usb_0 usb_1 ...)`
- `MIRROR_SIZE`, `THINPOOL_SIZE`, `USB_LV_SIZE` (defaults are tuned for 1TB)
- USB gadget IDs if you need custom VID/PID or serial
- NAS settings if you plan to use NAS sync

## 5) Install prerequisites
```
sudo install/00_prereqs.sh
```

## 6) Configure OTG (USB gadget)
```
sudo install/10_configure_otg.sh
```

## 7) SSH back in and run dry-run verifier
```
ssh <user>@<ip>
sudo install/05_verify_dryrun.sh
```
- Exit `0` = OK
- Exit `2` = warnings (review)
- Exit `1` = failures (fix before proceeding)

## 8) Initialize NVMe + LVM (destructive)
**WARNING:** This destroys NVMe contents.

To create the LVM layout:
```
sudo install/30_setup_nvme_lvm.sh --wipe
```
If you already created LVM manually:
```
sudo install/30_setup_nvme_lvm.sh
```

## 9) Install services and Python package
```
sudo install/40_install_services.sh
```

## 10) Configure Samba
```
sudo install/50_configure_samba.sh
```

## 11) Optional NAS
```
sudo install/60_configure_nas_optional.sh
```
Edit `/etc/vision-nas.creds` with NAS credentials.

## 12) Enable read-only overlay
```
sudo install/20_enable_readonly_overlay.sh
sudo reboot
```

## 13) Final reboot
```
sudo reboot
```

## 14) Validate
```
systemctl status usb-gadget.service
systemctl status vision-sync.timer vision-monitor.timer vision-rotator.timer
systemctl status smbd
```
Windows SMB check:
- `\\<cm5-ip>\vision_mirror`

## 15) Windows USB gadget check
1. Connect CM5 USB-C gadget port to Windows.
2. Windows should detect a **USB Mass Storage** device.
3. The CM5 **never mounts** the active FAT32 LV; only snapshots/offline LVs are mounted.

# Migration: demo CM5 IO Board → CM5-ETH-RS485-4G-BASE

Moves a running CitoStore from the demo unit to new hardware.

| | Old (demo) | New (target) |
|---|---|---|
| Module | CM5104032 | CM5002032 |
| RAM | 4 GB | **2 GB** |
| WiFi | yes | **none** |
| eMMC | 32 GB | 32 GB |
| Base board | CM5 IO Board | **CM5-ETH-RS485-4G-BASE** |
| NVMe | existing | **new, empty** |

**Chosen strategy: fresh OS install on the new hardware + config carry-over.**
Not a raw `dd` clone.

## Why not clone the eMMC

The OS image on eMMC is tuned to the old IO Board: `config.txt`/`cmdline.txt`
device-tree overlays, USB-OTG routing, and PMIC differ on the new base board. A
raw clone most likely won't boot, or boots but the USB gadget (the whole point
of the product) never comes up because the OTG path is different. The valuable,
portable state does **not** live in the OS image anyway — the real data is on
NVMe and the tunable config lives in `/srv/vision_mirror/.state`. So we reinstall
the OS clean and carry only the config.

Because the new NVMe is empty and only the configuration must survive, this is
the simplest possible migration.

---

## Phase 0 — Export config from the OLD device

With the old unit still running (SSH in):

```
cd /opt/vision-usb-gateway
sudo git pull                      # get export-config-bundle.sh
sudo scripts/export-config-bundle.sh
# -> /tmp/citostore-config-<host>-<date>.tgz
```

Copy the tarball off the device (from Windows):

```
scp <user>@<old-ip>:/tmp/citostore-config-*.tgz .
```

The bundle contains: `vision-gw.conf`, WebUI password/secret, NAS creds, the
`aoi_settings/` persist folder, the Samba password DB, and a copy of the
NetworkManager profiles (for reference — not auto-applied).

> Only config is migrated. The demo's synced images are intentionally dropped.

---

## Phase 1 — Flash a clean OS on the NEW eMMC (Win11 + rpiboot)

You already flash from this Win11 machine, so reuse that path.

1. Install **rpiboot** and **Raspberry Pi Imager** on Windows (already present
   from the original flashing).
2. Put the new CM5-ETH-RS485-4G-BASE into **eMMC boot (USB) mode** — set the
   boot jumper/switch on the base board per Waveshare docs, then connect the
   board's USB **slave/OTG** port to the PC.
3. Run `rpiboot.exe`. The 32 GB eMMC appears in Windows as a removable disk.
4. In **Raspberry Pi Imager**:
   - OS: *Raspberry Pi OS Lite (64-bit, Bookworm)*
   - Storage: the CM5 eMMC
   - Settings (gear): set **hostname**, **username**, **password**, enable
     **SSH**. **Do not** configure WiFi — this module has none; use Ethernet.
5. **Write**, eject.

This is the same as `docs/windows-install.md` §1, just via rpiboot instead of a
carrier flash switch.

---

## Phase 2 — First boot + hardware sanity on the new board

1. Install the **new empty NVMe** and boot the new board on Ethernet.
2. SSH in. Then verify the hardware differences before installing anything:

```
ip -o link                              # confirm the wired NIC is eth0
lsblk                                    # confirm NVMe is /dev/nvme0n1 and its size
ls /sys/class/udc                        # OTG/UDC controller present for gadget mode
cat /proc/device-tree/model             # confirm it's the new module
```

Three things to watch on this base board:

- **USB-OTG port.** The gadget uses the CM5 native USB2 in peripheral mode
  (`dtoverlay=dwc2,dr_mode=peripheral`, set by `install/10_configure_otg.sh`).
  Make sure the cable to the AOI/vision host goes to the **OTG-capable** USB
  connector, not a host-only USB-A. If `/sys/class/udc` is empty after step 3,
  the OTG port/overlay is wrong.
- **4G modem.** The base board's LTE modem enumerates over USB and ModemManager
  may grab it. It's harmless for storage, but if it adds boot noise or you don't
  use it: `sudo systemctl disable --now ModemManager`.
- **NIC name.** If the wired interface is not `eth0`, set `SMB_BIND_INTERFACE`
  accordingly in the config below.

---

## Phase 3 — Install CitoStore (same order as a fresh install)

```
sudo apt-get update -y && sudo apt-get install -y git
sudo git clone <your_repo_url> /opt/vision-usb-gateway
cd /opt/vision-usb-gateway

sudo install/00_prereqs.sh
sudo install/10_configure_otg.sh
sudo reboot          # OTG overlay + modules need a reboot
```

Back in after reboot:

```
cd /opt/vision-usb-gateway
sudo install/05_verify_dryrun.sh          # 0 = ok, 2 = warnings, 1 = fix first
sudo install/30_setup_nvme_lvm.sh --wipe  # builds LVM on the NEW empty NVMe
sudo install/40_install_services.sh
sudo install/50_configure_samba.sh
```

---

## Phase 4 — Import the migrated config

```
cd /opt/vision-usb-gateway
sudo scripts/import-config-bundle.sh /path/to/citostore-config-*.tgz
```

This stages the old config as the WebUI shadow config and restores the WebUI +
Samba passwords and AOI settings. It then prints a **review checklist** —
because the hardware changed, do not blindly apply:

- `NVME_DEVICE` still `/dev/nvme0n1`
- `MIRROR_SIZE` / `THINPOOL_SIZE` / `USB_LV_SIZE` sized to the **new** NVMe
  (the old values assumed the demo's disk; too-large values fail LVM creation)
- `SMB_BIND_INTERFACE` matches the actual NIC from Phase 2
- **`USB_VOLUME_SERIAL` and `USB_SERIAL`/VID/PID kept identical** so the AOI
  host keeps the same drive letter and USB identity after the swap
- no key references a `wlan*` interface

Edit if needed, then apply:

```
sudo nano /srv/vision_mirror/.state/vision-gw.conf
sudo scripts/apply-shadow-config.sh
```

### Network
The old NetworkManager profiles are copied into `.state` for reference but not
auto-applied (interface names differ). If the old unit used a **static IP**,
either re-enter it in the WebUI (Network tab) or:

```
sudo nmcli connection import type wifi file ...   # NO — wired:
sudo nmcli connection import type ethernet file /srv/vision_mirror/.state/<name>.nmconnection
```
DHCP needs nothing.

---

## Phase 5 — 2 GB RAM note

The module has half the demo's RAM. Nothing needs changing for correctness, but:

- Overlay mode keeps root-fs writes in a tmpfs upper layer. `JOURNAL_RUNTIME_MAX_USE`
  (64M) already caps journald. Keep it.
- The mirror and all image data are on NVMe, not RAM — the sync process itself is
  light. No tuning required for typical AOI feeds.
- If you later see memory pressure under very high file rates, lower
  `COPY_CHUNK_BYTES` and keep `SYNC_LOG_EVERY=0`.

---

## Phase 6 — Enable overlay + validate

```
sudo install/20_enable_readonly_overlay.sh
sudo reboot
```

After reboot:

```
systemctl status usb-gadget.service vision-sync.timer smbd
ls /sys/class/udc                         # gadget bound
cat /run/vision-usb-active                # active USB LV
```

- Windows SMB: `\\<new-ip>\vision_mirror`
- USB gadget: connect the OTG port to the AOI host → a USB Mass Storage device
  appears with the **same drive letter** as the demo (thanks to the preserved
  volume serial). Write a test file; confirm it lands in `raw/` + `bydate/` on
  the next sync cycle.

---

## Rollback

The old device is untouched — nothing here writes to it after Phase 0. If the
new unit misbehaves, re-connect the demo and you are back where you started. Keep
the exported bundle until the new unit has run unattended for a full day.

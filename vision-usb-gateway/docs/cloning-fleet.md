# Cloning a fleet of identical units

Once one unit is dialled in on the **target** hardware (CM5002032 +
CM5-ETH-RS485-4G-BASE), producing more units is a **golden-image + first-boot**
clone, not a per-unit reinstall.

> This is the opposite of `docs/migration-cm5-eth-rs485-4g.md`. The migration
> crossed *different* hardware, so the eMMC image was not portable. Here every
> unit is *identical*, so the eMMC image **is** portable — cloning is correct.

Assumptions (confirmed for this fleet): **DHCP on every unit**, **shared WebUI +
SMB password**, **each unit gets its own empty NVMe**.

## What must NOT be shared across clones

A raw eMMC copy would duplicate per-unit identity. `prepare-golden-image.sh`
strips these and `vision-firstboot.service` regenerates them per unit:

| Item | Handled by |
|---|---|
| `/etc/machine-id` (DHCP client id, journald) | first-boot regenerates |
| SSH host keys `/etc/ssh/ssh_host_*` | first-boot regenerates |
| hostname | first-boot → `citostore-<serial>` |
| WebUI session secret `webui.secret` | first-boot regenerates (fresh per unit) |
| the unit's NVMe / LVM | first-boot runs `30_setup_nvme_lvm.sh --wipe` |

**Intentionally shared** (travel on the eMMC image): the tuned
`/etc/vision-gw.conf`, `/etc/vision-nas.creds`, the Samba password DB, and the
WebUI password (stashed to `/etc/citostore-seed/` by the golden prep because the
live copy lives on the per-unit NVMe). `USB_VOLUME_SERIAL` / `USB_SERIAL` are
kept identical so every unit presents the same drive letter to its AOI host.

## Procedure

### 1. Build and dial in one golden unit
Full install on the target hardware (`docs/windows-install.md`), configure it via
the WebUI until it is exactly how every unit should ship.

### 2. De-personalise it
```
sudo install/21_disable_readonly_overlay.sh && sudo reboot   # overlay must be off
cd /opt/vision-usb-gateway
sudo scripts/prepare-golden-image.sh                 # add --fleet-overlay to
                                                     # re-enable overlay per unit
sudo poweroff
```

### 3. Read the eMMC to an image (Win11 + rpiboot)
Boot the golden board in eMMC/rpiboot mode, run `rpiboot.exe`, then **read** the
eMMC to a file:
- Raspberry Pi Imager has no "read"; use `dd` from a Linux box, or **Win32 Disk
  Imager** "Read" on Windows, or `usbimager`.
- Result: `citostore-golden.img` (~32 GB; shrink with `pishrink` if you want
  faster writes).

### 4. Clone each new unit
For every board:
1. rpiboot mode → write `citostore-golden.img` to its eMMC.
2. Install that unit's **own empty NVMe**.
3. Boot on Ethernet (DHCP).

First boot runs once, automatically:
- unique machine-id + SSH host keys + `citostore-<serial>` hostname
- initialises the empty NVMe (LVM), mounts `/srv/vision_mirror`
- seeds the shared WebUI password, generates a fresh session secret
- starts the stack; if built with `--fleet-overlay`, re-enables the read-only
  overlay and reboots once
- writes `/etc/citostore-firstboot-done` and disables itself

Per-unit hands-on time is ~2–3 min of imaging, then it self-configures.

### 5. Verify each unit
```
ssh <user>@<dhcp-ip>
hostnamectl                                  # unique citostore-<serial>
systemctl status usb-gadget.service vision-sync.timer smbd
ls /sys/class/udc                            # gadget bound
```
- WebUI at `http://<ip>/` — logs in with the shared password.
- SMB `\\<ip>\vision_mirror` — shared SMB password.
- Connect the OTG port to that unit's AOI host; confirm the drive appears and a
  test write syncs.

## Notes

- **An empty NVMe never wedges boot**: the golden prep marks the mirror mount
  `nofail`, and first-boot creates the LVM before the vision services start.
- **Re-imaging a unit**: writing the golden image again resets the done flag
  (it is not on the golden image), so first-boot personalisation runs afresh.
- **Static IPs later**: not needed for this fleet (DHCP), but any unit can be
  switched in the WebUI → Network tab without re-imaging.
- **Rotating the shared password**: change it on the golden unit and re-image, or
  change per unit in the WebUI. There is no central push.

# Troubleshooting

USB gadget not enumerating
- Check `/boot/firmware/config.txt` has `dtoverlay=dwc2,dr_mode=peripheral`
- Check `/boot/firmware/cmdline.txt` includes `modules-load=dwc2`
- Verify `modprobe dwc2` and `libcomposite` load
- `systemctl status usb-gadget.service`
- `ls /sys/class/udc`

Sync not copying
- `journalctl -u vision-sync.service`
- Confirm `/run/vision-usb-active` points to a valid LV
- Check snapshot LV `lvs` and mount at `/mnt/vision_snap`

Rotation not switching
- `cat /run/vision-rotate.state`
- Verify `SWITCH_WINDOW_*` in config
- `journalctl -u vision-rotator.service`

Thinpool metadata issues
- `lvs -o+metadata_percent vg0/usbpool`
- Consider increasing metadata or reducing snapshot retention

NAS mount issues
- `systemctl status mnt-nas.automount mnt-nas.mount`
- `journalctl -u nas-sync.service`

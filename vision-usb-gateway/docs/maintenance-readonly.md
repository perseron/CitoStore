# Read-only Maintenance

The root filesystem is protected by overlayfs with a tmpfs upper layer.
This keeps the OS read-only while NVMe stays writable.

Enable overlay
- `install/20_enable_readonly_overlay.sh` adds `overlayroot=tmpfs:recurse=0` to cmdline.

Maintenance mode (overlay off)
1) `sudo install/21_disable_readonly_overlay.sh`
2) Reboot
3) Perform upgrades or configuration changes
4) `sudo install/20_enable_readonly_overlay.sh`
5) Reboot

Optional boot partition RW
- If you enabled `--boot-ro`, run `sudo install/21_disable_readonly_overlay.sh --boot-rw` before reboot.

Journald
- Logs are volatile to avoid wear. Persistent logs should be written to `/srv/vision_mirror/.state`.

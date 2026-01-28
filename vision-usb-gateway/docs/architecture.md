# Architecture

Goals
- CM5 acts as a USB Mass Storage device to the vision host.
- Images are mirrored to NVMe and served over SMB.
- Optional NAS mirror is best-effort and must not block the core pipeline.
- Root filesystem is read-only via overlayfs with tmpfs upper; NVMe stays writable.

Key decisions
- USB gadget uses ConfigFS + libcomposite with dwc2 in peripheral mode.
- The active host-written FAT32 LV is never mounted. Sync uses thin snapshots (RO) or offline LVs.
- Overlay root uses `overlayroot=tmpfs:recurse=0` to keep NVMe mounts RW on Bookworm. This is applied via cmdline and optional raspi-config activation.
- Mirror retention uses sqlite state to delete both raw and bydate hardlinks safely.
- FAT32 4GiB limit: the sync skips files at or above 4GiB and never creates >4GiB files.

Data layout
- NVMe LVM:
  - `vg0/mirror` ext4 mounted at `/srv/vision_mirror`
  - `vg0/usbpool` thinpool
  - `vg0/usb_0..usb_(N-1)` FAT32 LVs, same label
- Mirror:
  - `raw/` authoritative storage
  - `bydate/YYYY/MM/DD/` hardlinks to raw
  - `.state/` sqlite and logs

Rotation
- `vision-monitor` watches LVM usage and thinpool metadata.
- `vision-rotator` switches LVs only in a window, unless critical threshold.
- The previous LV is processed offline and returned to the ring.

Snapshot sync
- Every 2-3 minutes, a thin snapshot of the active LV is mounted RO.
- Files are considered stable after two scans with identical size+mtime.
- Files are atomically copied to raw, then linked into bydate.

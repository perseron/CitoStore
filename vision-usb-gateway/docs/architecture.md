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

Operational description (detailed)
1) Boot + baseline mounts
   - NVMe mirror LV mounts at `/srv/vision_mirror` (ext4, RW).
   - Persistent state lives under `/srv/vision_mirror/.state`.
   - The last active USB LV path is stored in `/srv/vision_mirror/.state/vision-usb-active`.
2) USB gadget exposure
   - `usb-gadget.service` binds exactly one FAT32 LV to the USB Mass Storage gadget.
   - The host sees only the active LV; the CM5 never mounts the active LV.
   - On reboot, the gadget restores the previously active LV from the persisted file; if missing, it falls back to the first LV in `USB_LVS`.
3) Sync scheduler
   - `vision-sync.timer` controls sync cadence:
     - `SYNC_ONBOOT_SEC` schedules the first run after boot.
     - `SYNC_ONACTIVE_SEC` schedules a run after the timer is activated.
     - `SYNC_INTERVAL_SEC` schedules subsequent runs after a successful run.
4) Snapshot creation + RO mount
   - `vision-sync.service` creates a thin snapshot of the active LV (`SYNC_SNAPSHOT_NAME`).
   - The snapshot is activated and mounted read-only at `SYNC_MOUNT`.
   - The active LV remains unmounted to avoid host/CM5 conflicts.
5) File scan + stability
   - All files are enumerated from the snapshot; system folders like `System Volume Information` and `$RECYCLE.BIN` are skipped.
   - A file is considered stable only after `STABLE_SCAN_REQUIRED` consecutive scans with identical size+mtime.
   - This means a newly written file typically syncs on the second run if `STABLE_SCAN_REQUIRED=2`.
6) Copy + layout preservation
   - Stable files are copied into `raw/` while preserving the original folder structure from the USB LV.
   - The copy is atomic (temp file + rename), with SHA-256 used to derive a short content hash in the filename.
   - If a file with identical hash already exists, the temp copy is discarded and the existing file is reused.
7) By-date indexing
   - For each copied file, a hardlink is created in `bydate/YYYY/MM/DD/`.
   - `raw/` is authoritative; `bydate/` contains only hardlinks to raw content.
8) Persist folder handling (AOI settings)
   - If `USB_PERSIST_DIR` exists on the snapshot, a manifest hash is computed.
   - When the manifest changes, contents are synced to `USB_PERSIST_BACKING`.
   - The next LV in the ring is pre-seeded from the backing store.
   - `vision-rotator` verifies the persist folder on the next LV and auto-repairs if it drifts.
9) Rotation decision (monitor)
   - `vision-monitor` reads:
     - Active LV data usage (`THRESH_HI`/`THRESH_CRIT`; high-zone rotate requires `THRESH_HI_STABLE_SCANS` unchanged sync cycles)
     - Thinpool metadata usage (`META_HI`/`META_CRIT`)
   - It writes `/run/vision-rotate.state` with `state=ok|rotate_pending|panic`.
10) Rotation execution (rotator)
   - If `rotate_pending`, switching happens only within `SWITCH_WINDOW_START`–`SWITCH_WINDOW_END`.
   - If `panic`, switching happens immediately.
   - The gadget switches to the next LV and updates the persisted active LV file.
11) Offline maintenance of old LV
   - `offline-maint@<old_lv>` runs after switching:
     - FAT32 fsck
     - Offline sync (RO mount of the old LV)
     - Optional blkdiscard
     - Reformat to FAT32
     - Restore `USB_PERSIST_DIR` into the freshly formatted LV
12) Mirror retention
   - `mirror-retention` monitors mirror usage.
   - When usage exceeds `RETENTION_HI`, it deletes the oldest synced entry (raw + bydate hardlink) until usage falls below `RETENTION_LO`.

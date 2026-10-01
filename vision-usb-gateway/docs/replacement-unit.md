# Replacement units from a config bundle

A CitoStore unit's whole identity lives in one portable file &mdash; a
**`.citostore` config bundle**. Providing a spare/replacement unit is:

1. Flash a blank generic image and let it first-boot (see `cloning-fleet.md`).
2. Open its WebUI, upload the saved bundle, confirm.
3. The unit keeps the NVMe layout its first boot created (growing it if its
   disk is larger), restores the config + all secrets, and comes up as a
   drop-in for the failed unit.

No per-unit hand configuration; the bundle is the single source of truth.

## What the bundle contains

`.citostore` is a gzip archive (custom extension) holding **everything** needed
to reconstruct a unit:

- `vision-gw.conf` &mdash; all settings (timings, thresholds, USB layout, NetBIOS,
  network intent).
- WebUI password + session secret, NAS credentials, the AOI ingest FTP
  password and the mirror-FTP copy of the SMB password.
- The recorded network setting (`network.json`, e.g. a static IP).
- The Samba `passdb.tdb` (SMB users/passwords).
- `aoi_settings/` (the AOI persist folder backing).

It is **not encrypted** &mdash; keep it on trusted storage. The `.citostore`
extension just stops casual inspection.

## Save a bundle (from a working unit)

WebUI &rarr; **Config Bundle** &rarr; **Download Config Bundle**. Store the file
somewhere safe; re-download whenever the config changes.

CLI equivalent: `sudo scripts/export-config-bundle.sh /path/out.citostore`.

## Provision a replacement

WebUI &rarr; **Config Bundle** &rarr; **Provision from Bundle&hellip;** &rarr;
pick the `.citostore` file. The bundle's config is checked first (only plain
`KEY=value` lines, as for a config import — a crafted bundle must not run code
as root). The unit then shows **what it will do on its own NVMe** and asks you
to type `PROVISION` to confirm.

**Reuse (the normal case).** Every unit lays out its NVMe on its first boot, so
a replacement already has a mirror, a USB pool and USB drives. That layout is
**kept — nothing is wiped**, and images already on the unit stay. Then it:

- recreates (empty) only the USB drives whose size differs from the bundle's,
  growing the USB pool if they would not fit (refused if the NVMe has no room),
- grows the mirror online into any free space (a larger NVMe than the original),
- restores config + secrets + Samba passdb + aoi_settings + network setting,
- brings the stack up (WebUI restarts after ~1 min).

**Wipe (blank or incomplete layout).** When there is no mirror + USB pool to
reuse — a blank disk, or a first boot that could not lay out a smaller NVMe —
nothing is mounted, and the NVMe is wiped and partitioned for its own size (see
below) before the same restore.

A mounted, in-use mirror is **never** torn down: re-laying out a running disk is
unreliable (an LV held open cannot be removed, parted jams the disk, only a
reboot clears it) — the reason Factory Reset does its rebuild at early boot.
If something on the NVMe is mounted but there is no layout to reuse, the plan is
refused; use Factory Reset, then provision.

CLI equivalent:

```
sudo scripts/provision-from-bundle.sh bundle.citostore --plan            # preview
sudo scripts/provision-from-bundle.sh bundle.citostore --provision --confirm
```

## NVMe size adaptation

The replacement's NVMe need not match the original's. The **USB LV size and
count** (the Win98 host drives) are taken verbatim from the bundle; the **mirror
fills whatever NVMe this unit has** — on the reuse path by growing online into
free space (it is never shrunk), on the wipe path by this layout:

```
usbpool = N × USB_LV_SIZE + USB_LV_SIZE     (LVs + one LV of snapshot headroom)
meta    = 1 GiB
mirror  = NVMe_total − usbpool − meta − ~1% reserve
```

Examples for `USB_LV_SIZE=16G`, 3 LVs:

| NVMe | Mirror | USB drives |
|------|--------|-----------|
| 250 G | ~182 G | 3 × 16 G |
| 500 G | ~430 G | 3 × 16 G |
| 1 TB | ~856 G | 3 × 16 G |
| 2 TB | ~1.9 T | 3 × 16 G |

If the NVMe is too small for the configured USB layout (computed mirror < 20 G),
provisioning is refused &mdash; reduce `USB_LV_SIZE` in the bundle's config.

## Notes

- Provisioning is guarded by an explicit `PROVISION` confirmation. On the
  reuse path it is safe on a live unit: only the USB drives pause (and are
  recreated if their size changes); the mirror stays mounted.
- The config + secrets land on the persistent NVMe (the shadow config), so the
  read-only overlay keeps them across reboots.
- The Samba passdb is restored onto the overlay-safe bind mount
  (`/var/lib/samba` &rarr; `/srv/vision_mirror/.state/samba`), so SMB
  passwords survive reboots.

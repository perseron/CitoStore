# Replacement units from a config bundle

A CitoStore unit's whole identity lives in one portable file &mdash; a
**`.citostore` config bundle**. Providing a spare/replacement unit is:

1. Flash a blank generic image and let it first-boot (see `cloning-fleet.md`).
2. Open its WebUI, upload the saved bundle, confirm.
3. The unit wipes its NVMe, sizes the layout to its own disk, restores the
   config + all secrets, and comes up as a drop-in for the failed unit.

No per-unit hand configuration; the bundle is the single source of truth.

## What the bundle contains

`.citostore` is a gzip archive (custom extension) holding **everything** needed
to reconstruct a unit:

- `vision-gw.conf` &mdash; all settings (timings, thresholds, USB layout, NetBIOS,
  network intent).
- WebUI password + session secret, NAS credentials.
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
pick the `.citostore` file. The unit shows the **computed layout for its own
NVMe** and asks you to type `PROVISION` to confirm. Then it:

- wipes + repartitions the NVMe,
- restores config + secrets + Samba passdb + aoi_settings,
- brings the stack up (WebUI restarts after ~1 min).

CLI equivalent:

```
sudo scripts/provision-from-bundle.sh bundle.citostore --plan            # preview
sudo scripts/provision-from-bundle.sh bundle.citostore --provision --confirm
```

## NVMe size adaptation

The replacement's NVMe need not match the original's. The **USB LV size and
count** (the Win98 host drives) are taken verbatim from the bundle; the **mirror
is resized to fill whatever NVMe this unit has**:

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

- Provisioning is destructive and guarded by an explicit `PROVISION`
  confirmation; it also tears down any existing mounts/VG first, so it can
  re-provision a live unit, not just a blank one.
- Run it with the read-only overlay off (blank/first-boot unit). The config +
  secrets land on the persistent NVMe, so a later overlay flip keeps them.
- The Samba passdb is restored onto the overlay-safe bind mount
  (`/var/lib/samba` &rarr; `/srv/vision_mirror/.state/samba`), so SMB
  passwords survive reboots.

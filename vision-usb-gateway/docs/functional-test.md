# Functional Tests (Automated)

This repo includes automated functional tests for server-side services and Windows client behavior.

## Server-side test (CM5)

Run as root on the CM5:

```
sudo /opt/vision-usb-gateway/tests/functional/server/vision-functional.sh
```

Options:
- `--config /etc/vision-gw.conf` (override config path)
- `--destructive` (forces LV switching during rotator test and validates gadget LUN)
- `--nas-sync` (runs NAS sync when `NAS_ENABLED=true`)

Notes:
- Default mode is non-destructive. It will not intentionally switch the active USB LV.
- The sync test triggers `vision-sync.service` and reports whether it ran successfully.
- If no new files were written by the host, the sync test may warn (no new files detected).

## Windows client test

Run on the Windows host (PowerShell):

```
powershell -ExecutionPolicy Bypass -File .\tests\functional\windows\vision-functional.ps1 `
  -ShareHost <cm5-ip-or-hostname> `
  -UsbLabel VISIONUSB `
  -ShareName vision_mirror
```

Optional SMB credentials:

```
powershell -ExecutionPolicy Bypass -File .\tests\functional\windows\vision-functional.ps1 `
  -ShareHost <cm5-ip-or-hostname> `
  -SmbUser smbuser `
  -SmbPass <password>
```

What the Windows test does:
- Detects the USB mass-storage volume by label.
- Writes a small test file to the USB volume.
- Polls the SMB share for the synced file in `/raw` (and `/bydate` when available).

Parameters:
- `-UsbLabel` (default `VISIONUSB`)
- `-ShareHost` (required)
- `-ShareName` (default `vision_mirror`)
- `-TimeoutSec` (default `180`)
- `-PollSec` (default `5`)
- `-WaitForRotate` (wait for USB detach/reattach after server rotation)
- `-Cleanup` (removes the USB test file)

## Load test (Windows + server)

Windows (generate load):
```
powershell -ExecutionPolicy Bypass -File .\tests\functional\windows\vision-load.ps1 `
  -UsbLabel VISIONUSB `
  -FileSizeMB 2 `
  -IntervalSec 1 `
  -DurationSec 300
```

Server (verify rotation under load using low temporary thresholds):
```
sudo ./tests/functional/server/vision-load-test.sh --test-thresh 5 --timeout 300
```

Notes:
- The server script uses a temporary config with low thresholds to force a rotation once usage grows.
- Run the Windows load first, then start the server load test.

## Retention test (ring storage)

This test verifies the oldest mirror entry is deleted first.

```
sudo ./tests/functional/server/vision-retention-test.sh
```

Live check (no deletion, inspects real DB):
```
sudo ./tests/functional/server/vision-retention-test.sh --live
```

## Utility scripts

Resize USB LVs:
```
sudo /opt/vision-usb-gateway/scripts/resize-usb-lvs.sh --size 4G --force
```

Resize + update config:
```
sudo /opt/vision-usb-gateway/scripts/resize-usb-lvs.sh --size 4G --force --update-config
```

Wipe all data (mirror + USB LVs + sync state DB):
```
sudo /opt/vision-usb-gateway/scripts/wipe-all-data.sh --i-know-what-im-doing --force-umount
```

## Expected results

PASS:
- USB gadget active and bound to UDC
- Mirror mount present
- SMB service active
- Sync service runs successfully
- New files written on Windows appear in SMB `/raw`

WARN (non-fatal):
- No new files detected during sync run
- NAS disabled when NAS tests are skipped

FAIL:
- Services inactive
- USB gadget not bound
- SMB share unreachable
- Synced file not found within timeout

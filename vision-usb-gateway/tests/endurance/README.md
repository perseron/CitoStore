# Endurance test (tartóssági teszt)

Runs the REAL data paths for hours or days, under the conditions of the field:
the Windows test PC plays both AOIs, the board rotates its USB drives,
retention deletes, and the board is rebooted under load — and every file the
AOIs were told is written must end up in the mirror (or have been deleted by
retention, oldest first), while every 7/24 invariant stays green.

## Components

- `host-writer.ps1` — the USB AOI: bursts of 12 unique 2 MB images every 6 s
  (~4 MB/s) into the AOI's 4-level folder tree on the gadget drive (VISIONUSB);
  name + SHA256 + path of every write the host accepted in `writer.csv`.
- `ftp-writer.py` — the Ethernet AOI: one unique 1 MB file every 5 s over FTP
  and SFTP in turn to eth1; every accepted upload in `ftp-writer.csv`.
- `board-monitor.sh` — samples the board every 60 s into `monitor.csv`
  (health, failed units, I/O errors, power/throttling, memory, temperature,
  rotation, sync liveness, DB rows, mirror %, newest upload, pending exports,
  retention blocked, drives recycled unsaved) and writes an `ALERT` line to
  `alerts.log` when an invariant breaks. A reboot not announced by chaos.sh is
  an alert of its own.
- `chaos.sh` — reboots the board under load every `REBOOT_EVERY` minutes:
  `MODE=soft` (systemctl reboot: nothing acknowledged may be lost) or
  `MODE=hard` (reboot -f -f, a crash: writes of the last seconds may be lost
  or damaged — accepted, reported separately).
- `verify-mirror.sh` — integrity: USB images through the sync DB (rows are
  kept when retention deletes; deletions must be strictly oldest-first),
  uploads in ingest/ (missing only if older than the oldest file kept), and a
  SHA256 sample of both (+ the bydate link's inode). Exit 0 = pass.
- `endurance.sh` — `start | status | verify | stop` for all of the above.

## Run (Git Bash on the test PC)

```bash
bash endurance.sh start      # defaults: soft reboot every 4 h, mirror pre-filled to 80%
bash endurance.sh status     # any time
bash endurance.sh verify     # any time; the run keeps going
bash endurance.sh stop       # stop, wait 3 min, verify, restore the board
```

`start` moves eth1 to `ETH1_TEST` (192.168.2.250, the PC's LAN) so the PC can
reach the FTP/SFTP, and fills the mirror with `endurance-fill.bin` up to
`FILL_PCT` so retention runs during the test (at ~4 MB/s it reaches 90% in
~6 h, then deletes back to 85% every ~3 h). `stop` removes the filler and
puts eth1 back on `ETH1_HOME`. Knobs: `BOARD`, `OUT` (default
`/d/endurance-run`), `REBOOT_EVERY` (minutes, 0 = none), `MODE`, `FILL_PCT`,
`FTP=0` (USB AOI only). The WebUI is not used.

The PC must not sleep (AC standby "never"), and the gadget drive must stay
visible as VISIONUSB.

## What "pass" means

Zero `ALERT` lines in `alerts.log`, `verify-mirror.sh` passes (MISSING 0, bad
0, deleted out of order 0), and every reboot in `events.log` is followed by a
`BOOT seen`. Write errors at the moment of a reboot or a drive rotation are
expected (the AOI gets an error and retries): they go to `write-errors.log`,
one line per streak; a writer failing without a break for 5 minutes is an
ALERT. A write the host accepted that never reaches the mirror is a failure.

Afterwards: the test images stay on the board — WebUI "Wipe All Data" (or
`systemctl start vision-wipe.service`) clears them. Keep or delete `$OUT`.

# Endurance test (tartóssági teszt)

Exercises the REAL data path continuously: the Windows host plays the AOI and
writes unique 2MB "images" to the gadget drive (VISIONUSB); the board must
capture every one of them into the mirror through rotations, retention and
reboots, while every 7/24 invariant stays green.

## Components

- `host-writer.ps1` (Windows) — writes `END_*.jpg` files with unique content to
  the VISIONUSB drive at a steady rate; records name+SHA256 into
  `D:\endurance-run\writer.csv`. Write errors are logged and retried (AOI
  semantics), never fatal.
- `board-monitor.sh` (Git Bash, same PC) — samples the board over SSH every
  60s into `monitor.csv`: health, failed units, Buffer I/O count, dmesg errors,
  MemAvailable, overlay %, SoC temp, rotation state, sync liveness, mirror file
  count + free space. Any broken invariant emits an `ALERT` line to
  `alerts.log` and stdout.
- `verify-mirror.sh` — end-of-run integrity check: every written file must
  exist under `raw/` (minus a grace window for the stability gate), and a
  random sample must hash-match. Exit 0 = pass.

## Run

```powershell
# terminal 1 (PowerShell): the load
.\host-writer.ps1                  # 2MB/s default; -IntervalMs 500 doubles it
```
```bash
# terminal 2 (Git Bash): the watcher
BOARD=192.168.2.162 bash board-monitor.sh
```
```bash
# any time / at the end: integrity
BOARD=192.168.2.162 bash verify-mirror.sh
```

## What "pass" means

Over the whole run: zero ALERT lines, verify-mirror exits 0, and the board's
`boot-trace.txt` shows no unexpected reboot. Rotations are expected and good
(the 16G LV rotates around 80%; at 2MB/s that is roughly every 1.8h) — the
proof is that files written across the rotation boundary still all land in the
mirror. Reboot-under-load and power-cut-under-load are worthwhile manual
extensions: stop nothing, just reboot/cut the board and let the monitor show
recovery; verify-mirror afterwards tells what (if anything) was lost.

Cleanup after a run: delete `END_*` from the mirror (`raw/` + `bydate/`) or use
WebUI "Wipe All Data" on a test unit; delete `D:\endurance-run`.

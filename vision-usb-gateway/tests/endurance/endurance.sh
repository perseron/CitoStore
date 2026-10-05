#!/usr/bin/env bash
# Endurance run control (Git Bash on the Windows test PC that plays the AOI):
#   bash endurance.sh start    prepare the board, start the four components
#   bash endurance.sh status   one screen: progress, last sample, alerts
#   bash endurance.sh verify   integrity check now (the run keeps going)
#   bash endurance.sh stop     stop everything, verify, restore the board
#
# Board preparation (undone by stop):
# - eth1 moves to ETH1_TEST (on the PC's LAN) so the PC can play the Ethernet
#   AOI too; back to ETH1_HOME afterwards.
# - a filler file brings the mirror to FILL_PCT, so retention runs during the
#   test: at the default load (~4 MB/s) it reaches RETENTION_HI (90%) in a few
#   hours, then deletes down to 85% every few hours after that.
# Components run detached (they outlive this shell); PIDs in $OUT/pids.txt.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export BOARD=${BOARD:-10.10.10.1}
export OUT=${OUT:-/d/endurance-run}
ETH1_TEST=${ETH1_TEST:-192.168.2.250}
ETH1_HOME=${ETH1_HOME:-192.168.100.1}
FILL_PCT=${FILL_PCT:-80}
REBOOT_EVERY=${REBOOT_EVERY:-240}
MODE=${MODE:-soft}
FTP=${FTP:-1}                 # 0: USB AOI only
M=/srv/vision_mirror

sshb() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
      -o LogLevel=ERROR -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519" "citostore@$BOARD" "$@"
}
win() { cygpath -w "$1"; }
# A detached, hidden Windows process; its PID goes to pids.txt. The argument
# string is passed as one: Start-Process does not quote array elements.
launch() {  # <name> <exe> <argument string>
  local pid
  pid=$(powershell.exe -NoProfile -Command \
    "(Start-Process -FilePath '$2' -ArgumentList '${3//\'/\'\'}' -WindowStyle Hidden -PassThru).Id" | tr -d '\r')
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "could not start $1" >&2; exit 1; }
  echo "$1 $pid" >> "$OUT/pids.txt"
  echo "  started $1 (pid $pid)"
}
alive() { grep -q " $1 " < <(tasklist //FI "PID eq $1" //NH 2>/dev/null); }
set_eth1() {  # <address>: the shadow config, applied as the WebUI's Save + Apply does
  sshb "sudo bash -c 'sed -i \"s/^ETH1_ADDRESS=.*/ETH1_ADDRESS=$1/\" $M/.state/vision-gw.conf && \
    /opt/CitoStore/vision-usb-gateway/scripts/apply-shadow-config.sh >/dev/null 2>&1; ip -4 -br addr show eth1'"
}

cmd=${1:-}
case "$cmd" in
start)
  [[ ! -s "$OUT/pids.txt" ]] || { echo "a run is active ($OUT/pids.txt); stop it first" >&2; exit 1; }
  mkdir -p "$OUT"
  echo "== preflight"
  sshb 'head -1 /etc/citostore-build; systemctl is-system-running' || { echo "board $BOARD unreachable" >&2; exit 1; }
  powershell.exe -NoProfile -Command "if (-not (Get-Volume | ? FileSystemLabel -eq 'VISIONUSB')) { exit 1 }" \
    || { echo "no VISIONUSB drive on this PC" >&2; exit 1; }
  PY=$(python -c "import sys, paramiko; print(sys.executable)") || { echo "python with paramiko needed" >&2; exit 1; }
  if [[ "$FTP" == 1 ]]; then
    echo "== eth1 -> $ETH1_TEST (Ethernet AOI over the LAN)"
    set_eth1 "$ETH1_TEST"
    for _ in $(seq 1 20); do "$PY" -c "import ftplib;ftplib.FTP('$ETH1_TEST',timeout=3).quit()" 2>/dev/null && break; sleep 2; done
    "$PY" -c "import ftplib;ftplib.FTP('$ETH1_TEST',timeout=5).quit()" || { echo "FTP on $ETH1_TEST unreachable" >&2; exit 1; }
  fi
  echo "== mirror filled to ${FILL_PCT}% (retention runs during the test)"
  sshb "sudo python3 -c \"
import shutil, subprocess
t, u, _ = shutil.disk_usage('$M'); need = int(t * $FILL_PCT / 100 - u)
if need > 0: subprocess.run(['fallocate', '-l', str(need), '$M/endurance-fill.bin'], check=True)
t, u, _ = shutil.disk_usage('$M'); print(f'mirror at {u * 100 / t:.1f}%')\""
  echo "$(date -Is) START board=$BOARD mode=$MODE reboot_every=${REBOOT_EVERY}min fill=${FILL_PCT}% ftp=$FTP" >> "$OUT/events.log"
  echo "== components"
  launch writer powershell.exe "-NoProfile -ExecutionPolicy Bypass -File \"$(win "$HERE/host-writer.ps1")\" -OutDir \"$(win "$OUT")\""
  [[ "$FTP" == 1 ]] && launch ftp-writer "$PY" "\"$(win "$HERE/ftp-writer.py")\" --host $ETH1_TEST --out \"$(win "$OUT")\""
  GB=$(win /usr/bin/bash.exe 2>/dev/null || echo 'C:\Program Files\Git\bin\bash.exe')
  launch monitor "$GB" "-c \"BOARD=$BOARD OUT=$OUT exec bash '$HERE/board-monitor.sh' >> '$OUT/monitor.out' 2>&1\""
  [[ "$REBOOT_EVERY" -gt 0 ]] && launch chaos "$GB" "-c \"BOARD=$BOARD OUT=$OUT REBOOT_EVERY=$REBOOT_EVERY MODE=$MODE exec bash '$HERE/chaos.sh' >> '$OUT/chaos.out' 2>&1\""
  echo "running; data in $OUT. 'bash endurance.sh status' any time."
  ;;
status)
  [[ -f "$OUT/pids.txt" ]] || { echo "no run in $OUT"; exit 0; }
  echo "== $(head -1 "$OUT/events.log" 2>/dev/null)"
  while read -r name pid; do printf '  %-10s pid %-6s %s\n' "$name" "$pid" "$(alive "$pid" && echo running || echo STOPPED)"; done < "$OUT/pids.txt"
  w=$(( $(wc -l < "$OUT/writer.csv" 2>/dev/null || echo 1) - 1 ))
  f=$(( $(wc -l < "$OUT/ftp-writer.csv" 2>/dev/null || echo 1) - 1 ))
  echo "  USB images written: $w   Ethernet uploads: $f   reboots: $(cat "$OUT/events.log" 2>/dev/null | grep -c ' REBOOT ' || true)"
  if [[ -f "$OUT/monitor.csv" ]]; then
    echo "== last sample"
    paste -d= <(head -1 "$OUT/monitor.csv" | tr ',' '\n') <(tail -1 "$OUT/monitor.csv" | tr ',' '\n') | grep -vE '^(boot_id)=' | paste -sd' '
  fi
  echo "== write errors the AOIs got (expected at reboots/rotations): $(cat "$OUT/write-errors.log" 2>/dev/null | wc -l)"
  echo "== alerts: $(cat "$OUT/alerts.log" 2>/dev/null | grep -c ALERT || true)"
  tail -5 "$OUT/alerts.log" 2>/dev/null || true
  echo "== events"; tail -4 "$OUT/events.log" 2>/dev/null || true
  ;;
verify)
  bash "$HERE/verify-mirror.sh"
  ;;
stop)
  [[ -f "$OUT/pids.txt" ]] || { echo "no run in $OUT"; exit 0; }
  echo "== stopping"
  while read -r name pid; do taskkill //T //F //PID "$pid" >/dev/null 2>&1 && echo "  stopped $name" || echo "  $name already gone"; done < "$OUT/pids.txt"
  mv "$OUT/pids.txt" "$OUT/pids.stopped"
  echo "$(date -Is) STOP" >> "$OUT/events.log"
  echo "== waiting 3 min for the last files to sync (stability gate)"; sleep 180
  rc=0; bash "$HERE/verify-mirror.sh" | tee "$OUT/verify.txt" || rc=$?
  echo "== board restore"
  sshb "sudo rm -f $M/endurance-fill.bin"
  [[ "$FTP" == 1 ]] && set_eth1 "$ETH1_HOME"
  echo "alerts: $(cat "$OUT/alerts.log" 2>/dev/null | grep -c ALERT || true) (see $OUT/alerts.log); verify rc=$rc"
  echo "The test images stay on the board: WebUI Wipe All Data (or vision-wipe.service) clears them."
  exit $rc
  ;;
*)
  sed -n '2,8p' "$0"; exit 1 ;;
esac

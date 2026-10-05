#!/usr/bin/env bash
# Endurance monitor — samples the board's 7/24 invariants over SSH every
# INTERVAL seconds into monitor.csv, and emits an ALERT line (to alerts.log AND
# stdout) the moment any invariant breaks. Runs next to host-writer.ps1 and
# ftp-writer.py; alerts.log is one shared channel for all of them.
#
# Progress is read from the sync DB (rows are kept when retention deletes a
# file, so its row count only grows), not by counting raw/: with retention
# deleting as fast as the AOI writes, the file count stands still, and a
# find over the whole mirror every minute is load the real unit never has.
set -uo pipefail

BOARD=${BOARD:-10.10.10.1}
OUT=${OUT:-/d/endurance-run}
INTERVAL=${INTERVAL:-60}
# After a reboot (boot_id changed) the unit needs a few minutes to settle:
# no alerts from the sample checks until then, only "unreachable".
SETTLE=${SETTLE:-300}

mkdir -p "$OUT"
CSV="$OUT/monitor.csv"
ALERTS="$OUT/alerts.log"
EVENTS="$OUT/events.log"
[[ -f "$CSV" ]] || echo "ts,boot_id,uptime_s,health,boot_health,failed,bufio,throttled,mem_mb,ovl_pct,temp_c,rot,active,sync_age,usb_pct,db_rows,mirror_pct,ingest_newest_age,pending_oldest_age,blocked,not_saved,writer_files,ftp_files" > "$CSV"

sshb() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
      -o LogLevel=ERROR -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519" "citostore@$BOARD" "$@"
}

# Rate-limited: one line per condition per 10 minutes.
declare -A last_alert
alert() {
  local key="$1"; shift
  local now; now=$(date +%s)
  (( now - ${last_alert[$key]:-0} < 600 )) && return 0
  last_alert[$key]=$now
  echo "$(date -Is) ALERT $*" | tee -a "$ALERTS"
}
event() { echo "$(date -Is) $*" | tee -a "$EVENTS"; }
lines() { local n; n=$(wc -l < "$1" 2>/dev/null) || n=1; echo $(( n > 0 ? n - 1 : 0 )); }

prev_boot=""; boot_seen_at=0
prev_rows=-1; prev_writer=-1; prev_ftp=-1
rows_stall=0; writer_stall=0; ftp_stall=0

while true; do
  sample=$(sshb 'sudo bash -s' <<'EOF' 2>/dev/null
M=/srv/vision_mirror
# status:count — without "USB rotation pending" (the normal moment between 80%
# and the switch); "USB usage critical" (92%, a forced rotation) as usbcrit.
j() { python3 -c "
import json, sys
d = json.load(open(sys.argv[1])); iss = [i for i in d['issues'] if not i.startswith('USB rotation pending')]
crit = [i for i in iss if i.startswith('USB usage critical')]
print('usbcrit:1' if crit and len(iss) == 1 else ('ok' if not iss else d['status']) + ':' + str(len(iss)))" "$1" 2>/dev/null || echo none; }
boot=$(cat /proc/sys/kernel/random/boot_id)
up=$(cut -d. -f1 /proc/uptime)
failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
bufio=$(dmesg 2>/dev/null | grep -c "Buffer I/O")
thr=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
mem=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
ovl=$(df --output=pcent / | awk 'NR==2{gsub(/[ %]/,"");print}')
temp=$(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000 ))
rot=$(grep '^state=' /run/vision-rotate.state 2>/dev/null | cut -d= -f2)
active=$(basename "$(cat /run/vision-usb-active 2>/dev/null)" 2>/dev/null)
age=$(( $(date +%s) - $(stat -c %Y /run/vision-usb-usage.json 2>/dev/null || echo 0) ))
usb=$(python3 -c 'import json;print(json.load(open("/run/vision-usb-usage.json"))["percent"].rstrip("%"))' 2>/dev/null || echo "?")
rows=$(python3 -c "import sqlite3;c=sqlite3.connect('file:$M/.state/vision.db?mode=ro',uri=True,timeout=10);print(c.execute('select coalesce(max(id),0) from synced_files').fetchone()[0])" 2>/dev/null || echo "?")
mpct=$(python3 -c "import shutil;t,u,_=shutil.disk_usage('$M');print(round(u*100/t,1))")
newest=$(find "$M/ingest/data" -type f -printf '%C@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
iage=$(( newest ? $(date +%s) - newest : -1 ))
pend=-1
for f in "$M"/.state/usb-maint-pending.*; do [[ -e "$f" ]] || continue; a=$(( $(date +%s) - $(stat -c %Y "$f") )); (( a > pend )) && pend=$a; done
blocked=$([[ -e $M/.state/retention-blocked.json ]] && echo 1 || echo 0)
notsaved=$([[ -e $M/.state/export-not-saved.json ]] && echo 1 || echo 0)
echo "$boot,$up,$(j /run/vision-health.json),$(j /run/vision-health-boot.json),$failed,$bufio,${thr:-?},$mem,$ovl,$temp,${rot:-?},${active:-?},$age,$usb,$rows,$mpct,$iage,$pend,$blocked,$notsaved"
EOF
  )
  ts=$(date -Is); now=$(date +%s)
  if [[ -z "$sample" ]]; then
    # A reboot (chaos.sh) takes ~1-2 min; longer is an outage.
    (( now - ${unreach_since:=$now} >= 240 )) && alert unreachable "board unreachable at $BOARD for $(( now - unreach_since ))s"
    sleep "$INTERVAL"; continue
  fi
  unset unreach_since
  writer=$(lines "$OUT/writer.csv"); ftp=$(lines "$OUT/ftp-writer.csv")
  echo "$ts,$sample,$writer,$ftp" >> "$CSV"
  IFS=, read -r boot up health bhealth failed bufio thr mem ovl temp rot _active age _usb rows _mpct iage pend blocked notsaved <<< "$sample"

  if [[ -n "$prev_boot" && "$boot" != "$prev_boot" ]]; then
    # Expected only right after chaos.sh logged a reboot.
    last_reboot=$(grep -h ' REBOOT ' "$EVENTS" 2>/dev/null | tail -1 | cut -d' ' -f1)
    if [[ -n "$last_reboot" ]] && (( now - $(date -d "$last_reboot" +%s) < 900 )); then
      event "BOOT seen (uptime ${up}s, boot health $bhealth)"
    else
      alert reboot "UNEXPECTED reboot (uptime ${up}s, boot health $bhealth)"
    fi
    boot_seen_at=$now; rows_stall=0; prev_rows=-1
  fi
  prev_boot=$boot
  settled=$(( now - boot_seen_at >= SETTLE && up >= SETTLE ))

  if ((settled)); then
    # A forced rotation at 92% is the design under nonstop writing; still
    # critical after 3 samples means it did not happen.
    if [[ "$health" == usbcrit:1 ]]; then crit_n=$(( ${crit_n:-0} + 1 )); else crit_n=0; fi
    (( crit_n >= 3 )) && alert usbcrit "USB usage critical for $crit_n samples: the forced rotation did not happen"
    [[ "$health" == "ok:0" || "$health" == usbcrit:1 ]] || alert health "health=$health"
    [[ "$failed" == 0 ]]               || alert failed "failed units: $failed"
    [[ "${age:-999}" -lt 180 ]]        || alert syncage "sync stalled: usage last written ${age}s ago"
    [[ "$pend" -lt 900 ]]              || alert pending "an export/reformat has been pending for ${pend}s"
  fi
  [[ "$bufio" == 0 ]]                  || alert bufio "Buffer I/O errors in dmesg: $bufio"
  [[ "$thr" == 0x0 ]]                  || alert power "throttled=$thr (undervoltage/overheat)"
  [[ "${ovl:-100}" -lt 50 ]]           || alert overlay "overlay at ${ovl}%"
  [[ "${temp:-99}" -lt 75 ]]           || alert temp "SoC temp ${temp}C"
  [[ "${mem:-0}" -gt 500 ]]            || alert mem "MemAvailable ${mem}MB"
  [[ "$rot" != panic ]]                || alert rot "rotator state: panic"
  [[ "$blocked" == 0 ]]                || alert blocked "retention cannot reach its target (retention-blocked.json)"
  [[ "$notsaved" == 0 ]]               || alert notsaved "a USB drive was recycled WITHOUT its images (export-not-saved.json)"

  # Capture: the DB must grow while the USB writer produces files.
  wd=$(( writer - prev_writer )); prev_writer=$writer
  if [[ "$rows" =~ ^[0-9]+$ ]] && ((settled)); then
    if (( rows == prev_rows && wd > 0 )); then
      rows_stall=$((rows_stall + 1))
      (( rows_stall >= 5 )) && alert capture "sync DB not growing (rows=$rows) for $rows_stall samples while the USB writer advanced"
    else rows_stall=0; fi
  fi
  [[ "$rows" =~ ^[0-9]+$ ]] && prev_rows=$rows
  # Ethernet AOI: its newest upload must be recent while ftp-writer produces.
  fd=$(( ftp - prev_ftp )); prev_ftp=$ftp
  if (( fd > 0 && settled )) && [[ "$iage" -lt 0 || "$iage" -gt 300 ]]; then
    alert ingest "ftp-writer advanced but the newest ingest file is ${iage}s old"
  fi
  # Writers alive.
  if (( wd == 0 && writer > 0 )); then writer_stall=$((writer_stall + 1)); else writer_stall=0; fi
  (( writer_stall >= 5 )) && alert writer "USB writer not producing for $writer_stall samples (at $writer files)"
  if (( fd == 0 && ftp > 0 )); then ftp_stall=$((ftp_stall + 1)); else ftp_stall=0; fi
  (( ftp_stall >= 5 )) && alert ftpwriter "ftp-writer not producing for $ftp_stall samples (at $ftp files)"

  sleep "$INTERVAL"
done

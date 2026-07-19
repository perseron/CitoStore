#!/usr/bin/env bash
# Endurance monitor — samples the board's 7/24 invariants over SSH every
# INTERVAL seconds into monitor.csv, and emits an ALERT line (to alerts.log AND
# stdout) the moment any invariant breaks. Run it next to host-writer.ps1; the
# alerts file is one shared channel for both.
set -uo pipefail

BOARD=${BOARD:-192.168.2.162}
OUT=${OUT:-/d/endurance-run}
INTERVAL=${INTERVAL:-60}

mkdir -p "$OUT"
CSV="$OUT/monitor.csv"
ALERTS="$OUT/alerts.log"
[[ -f "$CSV" ]] || echo "ts,health,failed,bufio,dmesg_err,mem_mb,ovl_pct,temp_c,rot,active,sync_age,usb_pct,raw_files,mirror_free_gb,writer_files" > "$CSV"

sshb() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
      -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519" "citostore@$BOARD" "$@"
}

# Rate-limited alerts: one line per condition per 10 minutes, or the tail of a
# broken invariant floods the chat without adding information.
declare -A last_alert
alert() {
  local key="$1"; shift
  local now; now=$(date +%s)
  local prev=${last_alert[$key]:-0}
  (( now - prev < 600 )) && return 0
  last_alert[$key]=$now
  echo "$(date -Is) ALERT $*" | tee -a "$ALERTS"
}

prev_raw=-1
prev_writer=-1
raw_stall=0
writer_stall=0

while true; do
  sample=$(sshb 'bash -s' <<'EOF' 2>/dev/null
health=$(python3 -c 'import json;d=json.load(open("/run/vision-health.json"));print(d["status"]+":"+str(len(d["issues"])))' 2>/dev/null || echo unknown)
failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
bufio=$(sudo dmesg 2>/dev/null | grep -c "Buffer I/O")
derr=$(sudo dmesg --level=err,crit 2>/dev/null | grep -cv nvmf)
mem=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
ovl=$(df --output=pcent / | awk 'NR==2{gsub(/[ %]/,"");print}')
temp=$(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000 ))
rot=$(grep '^state=' /run/vision-rotate.state 2>/dev/null | cut -d= -f2)
active=$(basename "$(cat /run/vision-usb-active 2>/dev/null)" 2>/dev/null)
age=$(( $(date +%s) - $(stat -c %Y /run/vision-usb-usage.json 2>/dev/null || echo 0) ))
usb=$(python3 -c 'import json;print(json.load(open("/run/vision-usb-usage.json"))["percent"])' 2>/dev/null || echo "?")
raw=$(sudo find /srv/vision_mirror/raw -type f 2>/dev/null | wc -l)
mfree=$(df --output=avail -BG /srv/vision_mirror 2>/dev/null | awk 'NR==2{gsub(/G/,"");print $1}')
echo "$health,$failed,$bufio,$derr,$mem,$ovl,$temp,${rot:-?},${active:-?},$age,$usb,$raw,$mfree"
EOF
  )
  ts=$(date -Is)
  if [[ -z "$sample" ]]; then
    alert unreachable "board unreachable at $BOARD"
    sleep "$INTERVAL"
    continue
  fi
  writer=$(( $(wc -l < "$OUT/writer.csv" 2>/dev/null || echo 1) - 1 ))
  echo "$ts,$sample,$writer" >> "$CSV"

  IFS=, read -r health failed bufio derr mem ovl temp rot active age usb raw mfree <<< "$sample"

  [[ "$health" == "ok:0" ]]            || alert health "health=$health"
  [[ "${failed:-1}" -eq 0 ]]           || alert failed "failed units: $failed"
  [[ "${bufio:-1}" -eq 0 ]]            || alert bufio "Buffer I/O errors in dmesg: $bufio"
  [[ "${age:-999}" -lt 180 ]]          || alert syncage "sync stalled: last usage write ${age}s ago"
  [[ "${ovl:-100}" -lt 50 ]]           || alert overlay "overlay at ${ovl}%"
  [[ "${temp:-99}" -lt 75 ]]           || alert temp "SoC temp ${temp}C"
  [[ "${mem:-0}" -gt 500 ]]            || alert mem "MemAvailable ${mem}MB"
  [[ "${rot:-}" != "panic" ]]          || alert rot "rotator state: panic"

  # Progress: the mirror must grow while the writer ACTUALLY produces files —
  # comparing against the writer's delta, not its total, or a stopped writer
  # reads as a capture failure.
  writer_delta=$(( writer - prev_writer )); prev_writer=$writer
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    if [[ "$raw" -eq "$prev_raw" && $writer_delta -gt 0 ]]; then
      raw_stall=$((raw_stall + 1))
      [[ $raw_stall -ge 5 ]] && alert capture "mirror not growing: raw=$raw for $raw_stall samples while writer advanced"
    else
      raw_stall=0
    fi
    prev_raw=$raw
  fi
  if [[ $writer_delta -eq 0 && $prev_writer -gt 0 ]]; then
    writer_stall=$((writer_stall + 1))
    [[ $writer_stall -ge 3 ]] && alert writer "writer not producing (stopped or crashed?) at $writer files"
  else
    writer_stall=0
  fi

  sleep "$INTERVAL"
done

#!/usr/bin/env bash
# End-of-run integrity check: every file the writer produced must exist in the
# mirror (raw/), and a random sample must hash-match the writer's recorded
# SHA256. Files written in the last GRACE seconds are excluded — the sync's
# stability gate (2 stable scans) legitimately hasn't copied them yet.
#
# The grace cutoff is computed from THIS machine's clock (NOW below), never the
# board's: the writer's timestamps are host-clock, and a board with a wrong
# clock (no RTC cell + no NTP is the normal field state) once classified
# 27,888 genuinely missing files as "too fresh" and reported missing: 0.
set -euo pipefail

BOARD=${BOARD:-192.168.2.162}
OUT=${OUT:-/d/endurance-run}
SAMPLE=${SAMPLE:-50}
GRACE=${GRACE:-180}
NOW=$(date +%s)

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8
          -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519")

scp "${SSH_OPTS[@]}" "$OUT/writer.csv" "citostore@$BOARD:/tmp/endurance-writer.csv"
ssh "${SSH_OPTS[@]}" "citostore@$BOARD" sudo GRACE="$GRACE" SAMPLE="$SAMPLE" NOW="$NOW" python3 - <<'PY'
import csv, hashlib, os, random, sys, time
from pathlib import Path

grace = int(os.environ.get("GRACE", "180"))
sample_n = int(os.environ.get("SAMPLE", "50"))
host_now = int(os.environ.get("NOW") or time.time())
skew = int(time.time()) - host_now
if abs(skew) > 120:
    print(f"WARNING: board clock is {skew:+d}s off the host clock -- "
          f"board-side timestamps (bydate/, journals) are unreliable")
raw = Path("/srv/vision_mirror/raw")

on_disk = {}
for p in raw.rglob("END_*.jpg"):
    on_disk[p.name] = p

rows = []
cutoff = host_now - grace
with open("/tmp/endurance-writer.csv", newline="") as f:
    for row in csv.DictReader(f):
        rows.append(row)

missing, recent_skipped = [], 0
for row in rows:
    if row["name"] not in on_disk:
        # ISO ts from powershell Get-Date -Format o
        try:
            from datetime import datetime
            ts = datetime.fromisoformat(row["ts"][:26]).timestamp()
        except Exception:
            ts = 0
        if ts > cutoff:
            recent_skipped += 1
        else:
            missing.append(row["name"])

candidates = [r for r in rows if r["name"] in on_disk]
random.shuffle(candidates)
bad_hash = []
for row in candidates[:sample_n]:
    h = hashlib.sha256(on_disk[row["name"]].read_bytes()).hexdigest()
    if h != row["sha256"]:
        bad_hash.append(row["name"])

print(f"writer files: {len(rows)}  in mirror: {len(candidates)}  "
      f"missing: {len(missing)}  in-grace (too fresh): {recent_skipped}")
print(f"hash sample: {min(sample_n, len(candidates))} checked, {len(bad_hash)} mismatch")
if missing[:10]:
    print("first missing:", missing[:10])
if bad_hash:
    print("HASH MISMATCH:", bad_hash)
sys.exit(1 if (missing or bad_hash) else 0)
PY

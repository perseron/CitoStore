#!/usr/bin/env bash
set -euo pipefail

# Retention deletes in ARRIVAL order (ext4 ctime: when the file landed on the
# mirror) across everything, from ONE walk of the trees:
# - USB images (raw/ + their bydate links) and Ethernet-AOI uploads
#   (ingest/data) interleaved — ingest used to go only after every USB image;
# - files the DB does not know (lost vision.db, rows an older version pruned)
#   in their place by age — they used to go last, so the NEWEST were deleted;
# - the AOI's own clock (mtime) does not matter — a PC set to 2099 kept its
#   files forever;
# - rows of files still on the mirror survive the 90-day row prune;
# - many protected files no longer stall it (one walk per deleted file before).
# Real loop-mounted ext4, filled past RETENTION_HI. Privileged container:
#   docker run --rm --privileged -v "$PWD:/gw:ro" python:3.11-slim-bookworm \
#     bash /gw/tests/functional/test_retention_order.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 ]] || { echo "run as root (losetup, mount)" >&2; exit 1; }
command -v mkfs.ext4 >/dev/null || { apt-get update -qq >/dev/null && apt-get install -y -qq e2fsprogs >/dev/null; }

TMP=$(mktemp -d)
MIRROR=$TMP/mirror
cleanup() { mountpoint -q "$MIRROR" && umount "$MIRROR"; rm -rf "$TMP"; }
trap cleanup EXIT

fresh_fs() {  # <size> [inodes]
  mountpoint -q "$MIRROR" && umount "$MIRROR"
  mkdir -p "$MIRROR"; rm -f "$TMP/fs.img"
  truncate -s "$1" "$TMP/fs.img"
  mkfs.ext4 -q -F -O ^has_journal ${2:+-N "$2"} "$TMP/fs.img" >/dev/null 2>&1
  mount -o loop "$TMP/fs.img" "$MIRROR"
  mkdir -p "$MIRROR/.state" "$MIRROR/raw" "$MIRROR/bydate" "$MIRROR/ingest/data"
  python3 - "$MIRROR/.state/vision.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE synced_files (id INTEGER PRIMARY KEY AUTOINCREMENT, source_path TEXT, size INT, mtime INT, raw_path TEXT, bydate_path TEXT, synced_at INT)")
c.execute("CREATE TABLE file_state (path TEXT, last_seen INT)")
c.commit()
PY
}
usage() { python3 -c "import shutil;t,u,_=shutil.disk_usage('$MIRROR');print(int(u*100/t))"; }
db() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); r=c.execute(sys.argv[2], sys.argv[3:]).fetchall(); c.commit(); print("\n".join("|".join(map(str,x)) for x in r))' "$MIRROR/.state/vision.db" "$@"; }

usb_image() {  # <name> [synced_at]: raw + bydate link + DB row, like the sync
  local raw="$MIRROR/raw/$1" link="$MIRROR/bydate/2026-10-05/$1"
  mkdir -p "$(dirname "$raw")" "$(dirname "$link")"
  head -c 2000000 /dev/urandom > "$raw"; ln "$raw" "$link"
  db "INSERT INTO synced_files (source_path,size,mtime,raw_path,bydate_path,synced_at) VALUES (?,?,0,?,?,?)" \
    "$1" 2000000 "$raw" "$link" "${2:-$(date +%s)}" >/dev/null
  sleep 0.05
}
ingest_file() { head -c 2000000 /dev/urandom > "$MIRROR/ingest/data/$1"; sleep 0.05; }
orphan() { mkdir -p "$MIRROR/raw/old"; head -c 2000000 /dev/urandom > "$MIRROR/raw/old/$1"; ln "$MIRROR/raw/old/$1" "$MIRROR/bydate/2026-01-01-$1"; sleep 0.05; }

CONF=$TMP/conf
printf 'MIRROR_MOUNT=%s\nRETENTION_HI=90\nRETENTION_LO=85\nINGEST_DIR=%s/ingest\nDB_MAINT_INTERVAL_SEC=0\n' "$MIRROR" "$MIRROR" > "$CONF"
retention() { CONF_FILE=$CONF timeout "${1:-120}" bash "$GW/scripts/mirror-retention.sh" > "$TMP/out" 2>&1; }
exists() { local r=""; for f in "$@"; do [[ -e "$f" ]] && r+="1" || r+="0"; done; echo "$r"; }

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

echo "=== arrival order across USB images, FTP uploads and untracked files ==="
fresh_fs 64M
orphan o1                       # untracked (DB lost) — the oldest
ingest_file i1.bin              # FTP, older than the next USB image
usb_image a2.jpg
touch -d 2099-01-01 "$MIRROR/raw/a2.jpg"   # the AOI's clock: irrelevant
ingest_file i2.bin
n=0; while (($(usage) < 93)); do usb_image "late$n.jpg"; n=$((n+1)); done
echo "  (filled to $(usage)%)"
order=("$MIRROR/raw/old/o1" "$MIRROR/ingest/data/i1.bin" "$MIRROR/raw/a2.jpg" "$MIRROR/ingest/data/i2.bin")
for ((k = 0; k < n; k++)); do order+=("$MIRROR/raw/late$k.jpg"); done
retention
check "ran" "$(grep -c 'files considered' "$TMP/out")" 1
gone=$(exists "${order[@]}")
echo "  (oldest -> newest, 0 = deleted: $gone)"
check "deleted exactly the oldest, in arrival order (USB, FTP and untracked alike, mtime 2099 too)" \
  "$([[ "$gone" =~ ^000+1+$ ]] && echo yes || echo no)" yes
check "  ... with their bydate links (space really freed)" \
  "$(exists "$MIRROR/bydate/2026-01-01-o1" "$MIRROR/bydate/2026-10-05/a2.jpg")" "00"
check "usage back at the target, not below it by more than one file" "$(( $(usage) <= 85 && $(usage) >= 80 ))" 1
check "rows of deleted images blanked (identity kept)" "$(db "SELECT raw_path FROM synced_files WHERE source_path='a2.jpg'")" ""
check "rows of kept images untouched" "$(db "SELECT count(*) FROM synced_files WHERE source_path='late$((n-1)).jpg' AND raw_path != ''")" 1

echo "=== the 90-day row prune keeps rows whose files are still there ==="
fresh_fs 64M
usb_image kept.jpg "$(( $(date +%s) - 100*86400 ))"
db "INSERT INTO synced_files (source_path,size,mtime,raw_path,bydate_path,synced_at) VALUES ('gone.jpg',1,0,'','',?)" "$(( $(date +%s) - 100*86400 ))" >/dev/null
n=0; while (($(usage) < 93)); do ingest_file "f$n"; n=$((n+1)); done
retention
check "row of a file on the mirror kept, though 100 days old" "$(db "SELECT count(*) FROM synced_files WHERE source_path='kept.jpg'")" 1
check "a reclaimed (blank) 100-day row pruned" "$(db "SELECT count(*) FROM synced_files WHERE source_path='gone.jpg'")" 0

echo "=== cannot get back to the target: said so at once, in the health banner too ==="
fresh_fs 64M
mkdir -p "$MIRROR/ingest/aoi_settings"
n=0; while (($(usage) < 93)); do head -c 2000000 /dev/urandom > "$MIRROR/ingest/aoi_settings/s$n"; n=$((n+1)); done
retention
check "recorded (nothing protected: the AOI's settings folder is never pruned)" \
  "$(grep -o '"protected": 0' "$MIRROR/.state/retention-blocked.json" 2>/dev/null)" '"protected": 0'
check "  ... and logged" "$(grep -c 'nothing it may delete is left' "$TMP/out")" 1
# shellcheck source=/dev/null
alarm=$(source <(tr -d '\r' < "$GW/scripts/common.sh"); MIRROR_MOUNT=$MIRROR retention_blocked_issues)
check "health banner: the reason and the consequence" \
  "$([[ "$alarm" == *"cannot free space below 85%: nothing else may be deleted"*"recycled WITHOUT their images"* ]] && echo yes || echo "$alarm")" yes
rm -f "$MIRROR"/ingest/aoi_settings/s*
retention
check "back under the target: the alarm is cleared" "$(test -e "$MIRROR/.state/retention-blocked.json" && echo still || echo cleared)" cleared

echo "=== many protected files do not stall it (one walk, not one per deletion) ==="
fresh_fs 256M 120000
mkdir -p "$MIRROR/raw/keep" "$MIRROR/raw/new"
python3 - "$MIRROR" <<'PY'
import os, sys, time
m = sys.argv[1]
blob = os.urandom(4096)
for i in range(20000):          # protected, and the oldest
    with open(f"{m}/raw/keep/k{i:05d}", "wb") as f: f.write(blob)
time.sleep(0.05)
for i in range(16000):
    with open(f"{m}/raw/new/n{i:05d}", "wb") as f: f.write(blob)
PY
printf '{"paths": ["raw/keep"]}' > "$MIRROR/.state/retention-protected.json"
n=0; while (($(usage) < 93)); do head -c 4000000 /dev/zero > "$MIRROR/raw/new/zz$n"; n=$((n+1)); sync; done
echo "  (36000 files, 20000 protected, filled to $(usage)%)"
s=$(date +%s); retention 300 || true; took=$(( $(date +%s) - s ))
check "finished well within its timeout (${took}s)" "$(( took < 120 ))" 1
check "reached the target" "$(( $(usage) <= 85 ))" 1
check "every protected file kept" "$(ls "$MIRROR/raw/keep" | wc -l)" 20000

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"

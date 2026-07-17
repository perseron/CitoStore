#!/usr/bin/env bash
set -euo pipefail

# Retention must never delete a folder an operator protected, on either of its two
# deletion paths (the synced_files-driven one and the oldest-file fallback), and
# must say so loudly when protection is what stops it reaching its target.
#
# This runs against a real loop-mounted filesystem that is genuinely filled past
# RETENTION_HI, with the production thresholds, because the alternative does not
# work: an earlier version passed env vars and never ran at all — load_config
# sources the config file and overrode them, the real disk sat at 6%, and the
# script exited at its usage gate before deleting anything. Every assertion
# passed vacuously. Hence CONF_FILE (which mirror-retention.sh honours) and a
# filesystem small enough to actually fill.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)

if [[ $(id -u) -ne 0 ]]; then
  echo "must run as root (mirror-retention.sh requires it, and so does losetup)" >&2
  exit 1
fi

TMP=$(mktemp -d)
MIRROR="$TMP/mirror"
IMG="$TMP/fs.img"
cleanup() {
  mountpoint -q "$MIRROR" && umount "$MIRROR" || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- a real filesystem, small enough to fill -------------------------------
mkdir -p "$MIRROR"
truncate -s 64M "$IMG"
# No journal: on a filesystem this small its ~4M is a large slice of the budget,
# and the sizes below are chosen against what is actually free.
mkfs.ext4 -q -F -O ^has_journal "$IMG" >/dev/null 2>&1
mount -o loop "$IMG" "$MIRROR"

# Never let this loose on the real mirror: the whole point is deleting files.
real=$(findmnt -no SOURCE /srv/vision_mirror 2>/dev/null || true)
here=$(findmnt -no SOURCE "$MIRROR")
if [[ "$MIRROR" == "/srv/vision_mirror" || ( -n "$real" && "$here" == "$real" ) ]]; then
  echo "REFUSING: test mirror resolves to the production mirror" >&2
  exit 1
fi

mkdir -p "$MIRROR/.state" "$MIRROR/raw/keep_me" "$MIRROR/raw/old_stuff" "$MIRROR/bydate"

usage() { python3 -c "import shutil;t,u,_=shutil.disk_usage('$MIRROR');print(int(u*100/t))"; }

# Fill adaptively rather than guessing sizes against ext4's overhead (a first
# attempt hard-coded 26M into a 32M image and ran out of space during setup).
#
# The protected data must be the bulk AND the oldest: retention then reaches for
# it first, and even after deleting everything unprotected, usage stays above
# RETENTION_HI. That is the case worth proving — protection holds, and the run
# reports that it is stuck rather than filling up quietly.
fill_to() { # <file> <target pct>
  local f="$1" target="$2"
  : >"$f"
  while (($(usage) < target)); do
    head -c 2000000 /dev/zero >>"$f" || break
    sync
  done
}

fill_to "$MIRROR/raw/keep_me/important.bin" 92
protected_size=$(stat -c%s "$MIRROR/raw/keep_me/important.bin")
head -c 2000000 /dev/zero >"$MIRROR/raw/old_stuff/junk.bin"
touch -d "2020-01-01" "$MIRROR/raw/keep_me/important.bin"
touch -d "2021-01-01" "$MIRROR/raw/old_stuff/junk.bin"
sync

printf '{"paths": ["raw/keep_me"]}' >"$MIRROR/.state/retention-protected.json"

python3 - "$MIRROR/.state/vision.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE synced_files (id INTEGER PRIMARY KEY, raw_path TEXT, bydate_path TEXT, synced_at INT)")
c.execute("CREATE TABLE file_state (path TEXT, last_seen INT)")
c.commit()
PY

# mirror-retention.sh honours CONF_FILE; plain env vars would be overwritten by
# load_config sourcing the real /etc/vision-gw.conf.
CONF="$TMP/test.conf"
cat >"$CONF" <<EOF
MIRROR_MOUNT=$MIRROR
RETENTION_HI=90
RETENTION_LO=85
INGEST_DIR=$MIRROR/ingest
DB_MAINT_INTERVAL_SEC=0
EOF

start_usage=$(usage)
echo "=== test filesystem starts at ${start_usage}% (needs >= 90 to exercise anything) ==="
if ((start_usage < 90)); then
  echo "  SETUP FAIL: not full enough; the run would exit at its usage gate" >&2
  exit 1
fi

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

CONF_FILE="$CONF" DRY_RUN=false timeout 120 bash "$GW/scripts/mirror-retention.sh" \
  >"$TMP/out.txt" 2>&1 || true

echo "=== the run actually did something ==="
check "reached the deletion logic" \
  "$(grep -qiE 'must run as root|state DB not found' "$TMP/out.txt" && echo no || echo yes)" "yes"
check "unprotected file was deleted" \
  "$(test -f "$MIRROR/raw/old_stuff/junk.bin" && echo still-there || echo gone)" "gone"

echo "=== protection holds ==="
check "protected file survived" \
  "$(test -f "$MIRROR/raw/keep_me/important.bin" && echo yes || echo no)" "yes"
check "protected file is intact (not truncated to make room)" \
  "$(stat -c%s "$MIRROR/raw/keep_me/important.bin" 2>/dev/null || echo 0)" "$protected_size"

echo "=== and it says so, rather than filling up quietly ==="
check "CRITICAL reported" \
  "$(grep -q CRITICAL "$TMP/out.txt" && echo yes || echo no)" "yes"
check "health marker written" \
  "$(test -f "$MIRROR/.state/retention-blocked.json" && echo yes || echo no)" "yes"

echo "=== an unreadable protection list must not silently unprotect everything ==="
printf 'not json at all' >"$MIRROR/.state/retention-protected.json"
if CONF_FILE="$CONF" DRY_RUN=false timeout 120 bash "$GW/scripts/mirror-retention.sh" \
    >"$TMP/out2.txt" 2>&1; then
  echo "  FAIL: ran anyway with an unreadable protection list"
  fail=1
else
  echo "  PASS: aborted rather than delete with an unreadable protection list"
fi
check "protected file still there after the failed run" \
  "$(test -f "$MIRROR/raw/keep_me/important.bin" && echo yes || echo no)" "yes"

echo "=== when nothing is protected, retention still frees space ==="
rm -f "$MIRROR/.state/retention-protected.json"
mkdir -p "$MIRROR/raw/more"
head -c 1000000 /dev/zero >"$MIRROR/raw/more/filler.bin"
sync
before=$(usage)
CONF_FILE="$CONF" DRY_RUN=false timeout 120 bash "$GW/scripts/mirror-retention.sh" \
  >"$TMP/out3.txt" 2>&1 || true
check "the big file is deleted once unprotected" \
  "$(test -f "$MIRROR/raw/keep_me/important.bin" && echo still-there || echo gone)" "gone"
check "no CRITICAL when nothing is protected" \
  "$(grep -q CRITICAL "$TMP/out3.txt" && echo yes || echo no)" "no"

exit $fail

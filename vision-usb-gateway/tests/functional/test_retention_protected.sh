#!/usr/bin/env bash
set -euo pipefail

# Retention must never delete a folder an operator protected, on either of its
# two deletion paths (the synced_files-driven one and the oldest-file fallback).
# Getting this wrong loses production data that someone explicitly asked to keep,
# so it is checked against a real mirror layout rather than by reading the code.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MIRROR="$TMP/mirror"
mkdir -p "$MIRROR/.state" "$MIRROR/raw/keep_me" "$MIRROR/raw/old_stuff" "$MIRROR/bydate"

# Oldest files are the ones retention reaches for first — put the protected
# folder there, so a run that ignores protection deletes it immediately.
head -c 200000 /dev/zero > "$MIRROR/raw/keep_me/important.bin"
head -c 200000 /dev/zero > "$MIRROR/raw/old_stuff/junk.bin"
touch -d "2020-01-01" "$MIRROR/raw/keep_me/important.bin"
touch -d "2021-01-01" "$MIRROR/raw/old_stuff/junk.bin"

printf '{"paths": ["raw/keep_me"]}' > "$MIRROR/.state/retention-protected.json"

python3 - "$MIRROR/.state/vision.db" <<'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE synced_files (id INTEGER PRIMARY KEY, raw_path TEXT, bydate_path TEXT, synced_at INT)")
c.execute("CREATE TABLE file_state (path TEXT, last_seen INT)")
c.commit()
PY

if [[ $(id -u) -ne 0 ]]; then
  echo "must run as root (the script requires it) — re-run with sudo" >&2
  exit 1
fi

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

echo "=== protected folder is skipped by the file fallback ==="
# RETENTION_HI=0 forces a run regardless of real disk usage; the loop deletes
# until nothing unprotected is left, which is exactly the "protection blocks
# retention" case (LO=0 is unreachable on a real filesystem).
MIRROR_MOUNT="$MIRROR" RETENTION_HI=0 RETENTION_LO=0 DRY_RUN=false \
  timeout 60 bash "$GW/scripts/mirror-retention.sh" >"$TMP/out.txt" 2>&1 || true

# Prove the run actually did something, or every check below passes vacuously.
check "the run reached the deletion logic" \
  "$(grep -qi 'must run as root' "$TMP/out.txt" && echo no || echo yes)" "yes"
check "protected file survived" \
  "$(test -f "$MIRROR/raw/keep_me/important.bin" && echo yes || echo no)" "yes"
check "unprotected file was deleted" \
  "$(test -f "$MIRROR/raw/old_stuff/junk.bin" && echo still-there || echo gone)" "gone"

echo "=== it says so loudly when protection blocks it ==="
check "CRITICAL reported" \
  "$(grep -c CRITICAL "$TMP/out.txt" >/dev/null && echo yes || echo no)" "yes"
check "health marker written" \
  "$(test -f "$MIRROR/.state/retention-blocked.json" && echo yes || echo no)" "yes"

echo "=== a bad protected file must not silently unprotect everything ==="
printf 'not json at all' > "$MIRROR/.state/retention-protected.json"
if MIRROR_MOUNT="$MIRROR" RETENTION_HI=0 RETENTION_LO=0 DRY_RUN=false \
    timeout 60 bash "$GW/scripts/mirror-retention.sh" >"$TMP/out2.txt" 2>&1; then
  echo "  FAIL: ran anyway with an unreadable protection list"; fail=1
else
  echo "  PASS: aborted rather than delete with an unreadable protection list"
fi
check "protected file still there after the failed run" \
  "$(test -f "$MIRROR/raw/keep_me/important.bin" && echo yes || echo no)" "yes"

exit $fail

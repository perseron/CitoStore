#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
  fi
}

require_root

LIVE=false

usage() {
  cat <<'EOF'
vision-retention-test.sh [--live]

Default: uses a temp mirror DB and performs a real delete.
--live: inspects the real DB and reports the oldest entry (no deletion).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live)
      LIVE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$LIVE" == "true" ]]; then
  MIRROR_MOUNT=${MIRROR_MOUNT:-/srv/vision_mirror}
  STATE="$MIRROR_MOUNT/.state/vision.db"
  if [[ ! -f "$STATE" ]]; then
    echo "state DB not found: $STATE" >&2
    exit 1
  fi
  python3 - <<PY
import sqlite3

db = r"$STATE"
conn = sqlite3.connect(db)
row = conn.execute(
  "SELECT raw_path, bydate_path, synced_at FROM synced_files ORDER BY synced_at ASC LIMIT 1"
).fetchone()
conn.close()
if row is None:
    raise SystemExit("no entries in synced_files")
print("Oldest entry:")
print(f"  raw_path={row[0]}")
print(f"  bydate_path={row[1]}")
print(f"  synced_at={row[2]}")
PY
  echo "PASS: live retention check (no deletion)"
  exit 0
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

MIRROR="$TMP_DIR/mirror"
STATE="$MIRROR/.state"
RAW="$MIRROR/raw"
BYDATE="$MIRROR/bydate/2024/01/01"
BYDATE2="$MIRROR/bydate/2024/01/02"
BYDATE3="$MIRROR/bydate/2024/01/03"

mkdir -p "$RAW" "$BYDATE" "$BYDATE2" "$BYDATE3" "$STATE"

echo "a" > "$RAW/a.txt"
echo "b" > "$RAW/b.txt"
echo "c" > "$RAW/c.txt"

# Simulate real layout with hard links.
ln "$RAW/a.txt" "$BYDATE/a.txt"
ln "$RAW/b.txt" "$BYDATE2/b.txt"
ln "$RAW/c.txt" "$BYDATE3/c.txt"

python3 - <<PY
import sqlite3
from pathlib import Path

db = Path("$STATE") / "vision.db"
conn = sqlite3.connect(str(db))
conn.execute("""
CREATE TABLE IF NOT EXISTS synced_files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_path TEXT,
  size INTEGER,
  mtime INTEGER,
  raw_path TEXT,
  bydate_path TEXT,
  synced_at INTEGER
)
""")
rows = [
  ("a.txt", 1, 1, "$RAW/a.txt", "$BYDATE/a.txt", 1),
  ("b.txt", 1, 1, "$RAW/b.txt", "$BYDATE2/b.txt", 2),
  ("c.txt", 1, 1, "$RAW/c.txt", "$BYDATE3/c.txt", 3),
]
conn.executemany(
  "INSERT INTO synced_files (source_path,size,mtime,raw_path,bydate_path,synced_at) VALUES (?,?,?,?,?,?)",
  rows,
)
conn.commit()
conn.close()
PY

export MIRROR_MOUNT="$MIRROR"
export RETENTION_HI=0
export RETENTION_LO=0
export DRY_RUN=false
export CONF_FILE=""

"$SCRIPT_DIR/../../../scripts/mirror-retention.sh"

python3 - <<PY
import sqlite3
from pathlib import Path

db = Path("$STATE") / "vision.db"
conn = sqlite3.connect(str(db))
rows = conn.execute("SELECT raw_path FROM synced_files ORDER BY synced_at ASC").fetchall()
conn.close()
remaining = [r[0] for r in rows]
print("Remaining:", remaining)
assert "$RAW/a.txt" not in remaining, "oldest row should be deleted"
assert "$RAW/b.txt" in remaining and "$RAW/c.txt" in remaining, "newer rows should remain"
PY

if [[ -e "$RAW/a.txt" || -e "$BYDATE/a.txt" ]]; then
  echo "FAIL: oldest files still exist" >&2
  exit 1
fi

if [[ ! -e "$RAW/b.txt" || ! -e "$RAW/c.txt" ]]; then
  echo "FAIL: newer files missing" >&2
  exit 1
fi

echo "PASS: mirror retention deletes oldest entry first"

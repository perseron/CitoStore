#!/usr/bin/env bash
set -euo pipefail

# nas-sync.sh copies the mirror to the NAS: never .state (session key, password
# hashes, passdb, credentials — onto a share others can read), never into a
# NAS mount point with nothing mounted on it (the RAM root), and rsync's 24
# (files vanished — retention/rotation at work) is a success. rsync and findmnt
# are stubbed. Root (require_root):
#   docker run --rm -v "$PWD:/gw:ro" debian:bookworm bash /gw/tests/functional/test_nas_sync.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 ]] || { echo "run as root (in a container)" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/mirror/.state" "$TMP/mirror/raw" "$TMP/nas"
printf '#!/bin/bash\necho "rsync $*" >> %s/calls\nexit $(cat %s/rsync_rc)\n' "$TMP" "$TMP" > "$TMP/bin/rsync"
printf '#!/bin/bash\ncat %s/fstype 2>/dev/null\n' "$TMP" > "$TMP/bin/findmnt"
chmod +x "$TMP/bin/"*
tr -d '\r' < "$GW/scripts/common.sh" > "$TMP/common.sh"
tr -d '\r' < "$GW/scripts/nas-sync.sh" > "$TMP/nas-sync.sh"
cat > "$TMP/conf" <<EOF
NAS_ENABLED=true
NAS_MOUNT=$TMP/nas
MIRROR_MOUNT=$TMP/mirror
NAS_RETRY_MAX=2
NAS_RETRY_BACKOFF=0
EOF

run() {  # <findmnt output> <rsync rc>
  rm -f "$TMP/calls" "$TMP/mirror/.state/nas-sync-status.json"
  printf '%b' "$1" > "$TMP/fstype"; echo "$2" > "$TMP/rsync_rc"
  sed -i "s#^CONF_FILE_DEFAULT=.*#CONF_FILE_DEFAULT=$TMP/conf#" "$TMP/common.sh"
  PATH="$TMP/bin:$PATH" bash "$TMP/nas-sync.sh" >/dev/null 2>&1 || true
}
status() { grep -o '"status":"[a-z]*"' "$TMP/mirror/.state/nas-sync-status.json" 2>/dev/null; }

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

run 'autofs\ncifs\n' 0
check "share mounted -> synced" "$(status)" '"status":"ok"'
check "  ... without .state" "$(grep -c -- '--exclude=/.state/' "$TMP/calls")" 1
run 'autofs\ncifs\n' 24
check "files vanished during the copy (rc 24) -> ok, one pass" "$(status):$(wc -l < "$TMP/calls")" '"status":"ok":1'
run 'autofs\ncifs\n' 23
check "a real rsync error -> failed after the retries" "$(status):$(wc -l < "$TMP/calls")" '"status":"failed":2'
run 'autofs\n' 0
check "only the automount, no share behind it -> nothing copied into the RAM root" "$(status):$(test -e "$TMP/calls" && echo copied || echo none)" '"status":"failed":none'
run '' 0
check "not a mount point at all -> nothing copied" "$(test -e "$TMP/calls" && echo copied || echo none)" none

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"

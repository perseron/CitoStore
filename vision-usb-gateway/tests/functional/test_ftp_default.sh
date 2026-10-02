#!/usr/bin/env bash
set -euo pipefail

# 70_configure_ingest.sh gives the ingest account (FTP + SFTP) the factory
# default password when none was set in the WebUI — and never touches one that
# was. System commands stubbed, in a throwaway container:
#   docker run --rm -v "$PWD:/src:ro" debian:bookworm bash -c \
#     'cp -r /src /gw && bash /gw/tests/functional/test_ftp_default.sh'
# It writes to /etc and /srv, so never run it on a real unit.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 ]] || { echo "run as root in a container" >&2; exit 1; }
[[ -f /.dockerenv ]] || { echo "refusing to run outside a container" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

FAKE=$TMP/gw
mkdir -p "$FAKE/scripts" "$FAKE/install"
tr -d '\r' < "$GW/scripts/common.sh" > "$FAKE/scripts/common.sh"
tr -d '\r' < "$GW/install/70_configure_ingest.sh" > "$FAKE/install/70_configure_ingest.sh"

mkdir -p "$TMP/bin"
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }
stub chpasswd "echo \"chpasswd \$(cat)\" >> $TMP/calls"
stub mountpoint "[[ -f $TMP/mounted ]]"
for c in systemctl useradd usermod id vsftpd sshd nmcli sysctl chown; do stub "$c" "exit 0"; done
export PATH="$TMP/bin:$PATH"
export GATEWAY_HOME=$FAKE

M=$TMP/mirror
mkdir -p "$M/.state"
CREDS=$M/.state/ftp.creds
run() {
  : > "$TMP/calls"
  printf 'GATEWAY_HOME=%s\nMIRROR_MOUNT=%s\nINGEST_ENABLED=true\nINGEST_DIR=%s/ingest\nFTP_ENABLED=true\nSFTP_ENABLED=false\nETH1_ENABLED=false\nFTP_USER=aoiftp\n' \
    "$FAKE" "$M" "$M" > /etc/vision-gw.conf
  bash "$FAKE/install/70_configure_ingest.sh" >"$TMP/out" 2>&1 || echo "rc=$?" >> "$TMP/out"
}

echo "=== no ingest password set: the factory default ==="
rm -f "$CREDS"; touch "$TMP/mounted"
run
check "default written to the NVMe secret" "$(cat "$CREDS")" "password=citostore"
check "  ... private" "$(stat -c %a "$CREDS")" 600
check "  ... applied to the account (FTP + SFTP both use it)" "$(grep -c '^chpasswd aoiftp:citostore$' "$TMP/calls")" 1
check "  ... and said so" "$(grep -c 'default password' "$TMP/out")" 1
check "the Ethernet AOI's settings folder exists next to data/" "$(stat -c %a "$M/ingest/aoi_settings" 2>/dev/null)" 755

echo "=== a password set in the WebUI is never replaced ==="
echo "password=Secret-1" > "$CREDS"
run
check "creds untouched" "$(cat "$CREDS")" "password=Secret-1"
check "the WebUI password is (re)applied" "$(grep -c '^chpasswd aoiftp:Secret-1$' "$TMP/calls")" 1
check "no default applied" "$(grep -c citostore "$TMP/calls")" 0

echo "=== NVMe not mounted: nothing written into the bare mount point ==="
rm -f "$CREDS" "$TMP/mounted"
run
check "no creds written" "$(test -e "$CREDS" && echo yes || echo no)" no
check "no password change" "$(grep -c chpasswd "$TMP/calls")" 0

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"

#!/usr/bin/env bash
set -euo pipefail

# 50_configure_samba.sh gives a unit with NO SMB user the factory default
# password (smbuser / citostore) — and never touches a password that is set.
# Samba/systemd stubbed, in a throwaway container:
#   docker run --rm -v "$PWD:/src:ro" debian:bookworm bash -c \
#     'cp -r /src /gw && bash /gw/tests/functional/test_smb_default.sh'
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
mkdir -p "$FAKE/scripts" "$FAKE/install" "$FAKE/conf/samba" "$FAKE/systemd"
tr -d '\r' < "$GW/scripts/common.sh" > "$FAKE/scripts/common.sh"
tr -d '\r' < "$GW/install/50_configure_samba.sh" > "$FAKE/install/50_configure_samba.sh"
tr -d '\r' < "$GW/conf/samba/smb.conf.template" > "$FAKE/conf/samba/smb.conf.template"
tr -d '\r' < "$GW/systemd/var-lib-samba.mount" > "$FAKE/systemd/var-lib-samba.mount"

mkdir -p "$TMP/bin"
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }
stub pdbedit "[[ -f $TMP/has_user ]] || { echo 'Username not found!'; exit 255; }"
stub smbpasswd "echo \"smbpasswd \$* [\$(head -1)]\" >> $TMP/calls"
stub chpasswd "echo \"chpasswd \$(cat)\" >> $TMP/calls"
stub mountpoint "[[ \"\${@: -1}\" == /var/lib/samba && -f $TMP/bound ]] || [[ \"\${@: -1}\" == /srv/vision_mirror ]]"
stub systemctl "exit 0"
stub useradd "exit 0"
stub id "exit 0"
export PATH="$TMP/bin:$PATH"
export GATEWAY_HOME=$FAKE

mkdir -p /etc/samba /srv/vision_mirror/.state /srv/vision_mirror/raw /srv/vision_mirror/bydate
CREDS=/srv/vision_mirror/.state/smb_unix.creds
run() {
  : > "$TMP/calls"
  printf 'GATEWAY_HOME=%s\nSMB_USER=smbuser\n%s' "$FAKE" "${1:-}" > /etc/vision-gw.conf
  bash "$FAKE/install/50_configure_samba.sh" >"$TMP/out" 2>&1 || echo "rc=$?" >> "$TMP/out"
}

echo "=== no SMB user (fresh NVMe / factory reset): factory default ==="
rm -f "$TMP/has_user" "$CREDS"; touch "$TMP/bound"
run
check "SMB password set to the default" "$(grep -c '^smbpasswd -s -a smbuser \[citostore\]' "$TMP/calls")" 1
check "  ... and enabled" "$(grep -c '^smbpasswd -e smbuser' "$TMP/calls")" 1
check "  ... same password for PAM (mirror FTP)" "$(grep -c '^chpasswd smbuser:citostore$' "$TMP/calls")" 1
check "  ... kept for the next boot's PAM re-apply" "$(cat "$CREDS")" "password=citostore"
check "  ... private" "$(stat -c %a "$CREDS")" 600

echo "=== a password already set (WebUI) is never overwritten ==="
touch "$TMP/has_user"; echo "password=Secret-1" > "$CREDS"
run
check "no smbpasswd" "$(grep -c smbpasswd "$TMP/calls")" 0
check "no chpasswd" "$(grep -c chpasswd "$TMP/calls")" 0
check "creds untouched" "$(cat "$CREDS")" "password=Secret-1"

echo "=== passdb lost its user but the WebUI-set password is saved: that one comes back ==="
rm -f "$TMP/has_user"
run
check "saved password into the passdb, not the default" "$(grep -c 'smbpasswd -s -a smbuser \[Secret-1\]' "$TMP/calls")" 1
check "  ... and PAM (one password for SMB + mirror FTP)" "$(grep -c '^chpasswd smbuser:Secret-1$' "$TMP/calls")" 1
check "creds file not replaced" "$(cat "$CREDS")" "password=Secret-1"

echo "=== Samba state not on the NVMe (bind missing): nothing seeded into RAM ==="
rm -f "$TMP/bound" "$CREDS"
run
check "no smbpasswd" "$(grep -c smbpasswd "$TMP/calls")" 0
check "no creds written" "$(test -e "$CREDS" && echo yes || echo no)" no
check "  ... says it will on the next boot" "$(grep -c 'default password on the next boot' "$TMP/out")" 1

echo "=== SMB_PASS in the config still wins ==="
touch "$TMP/bound" "$TMP/has_user"
run "SMB_PASS=fromconf"$'\n'
check "configured password applied" "$(grep -c 'smbpasswd -s -a smbuser \[fromconf\]' "$TMP/calls")" 1

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"

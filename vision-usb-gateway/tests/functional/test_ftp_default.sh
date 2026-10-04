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
for c in systemctl useradd usermod id vsftpd sshd sysctl chown; do stub "$c" "exit 0"; done
# nmcli: recorded; `-w 8 connection up` (eth1) answers with $TMP/up_rc; the
# active list and a profile's settings (-g) come from $TMP/active and
# $TMP/settings_N, N counting the -g reads (1 = before the modify, 2 = after).
cat > "$TMP/bin/nmcli" <<EOF
#!/bin/bash
echo "nmcli \$*" >> $TMP/calls
case "\$*" in
  "-t -f NAME,DEVICE connection show --active") cat $TMP/active 2>/dev/null; exit 0 ;;
  -g\ *) n=\$(( \$(cat $TMP/greads 2>/dev/null || echo 0) + 1 )); echo \$n > $TMP/greads
         cat $TMP/settings_\$n 2>/dev/null; exit 0 ;;
esac
[[ "\$1 \$2" == '-w 8' ]] && exit \$(cat $TMP/up_rc 2>/dev/null || echo 0)
exit 0
EOF
chmod +x "$TMP/bin/nmcli"
# NetworkManager's log, as 70 reads it after a failed eth1 activation.
stub journalctl "cat $TMP/nmlog 2>/dev/null; exit 0"
export PATH="$TMP/bin:$PATH"
export GATEWAY_HOME=$FAKE

M=$TMP/mirror
mkdir -p "$M/.state"
CREDS=$M/.state/ftp.creds
run() {  # [extra config lines...] (later lines win: the config is sourced)
  : > "$TMP/calls"
  printf 'GATEWAY_HOME=%s\nMIRROR_MOUNT=%s\nINGEST_ENABLED=true\nINGEST_DIR=%s/ingest\nFTP_ENABLED=true\nSFTP_ENABLED=false\nETH1_ENABLED=false\nFTP_USER=aoiftp\n' \
    "$FAKE" "$M" "$M" > /etc/vision-gw.conf
  local line
  for line in "$@"; do echo "$line" >> /etc/vision-gw.conf; done
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
touch "$TMP/mounted"

echo "=== SSH: the password accounts get no logins or tunnels; SFTP only on eth1 ==="
DROP=/etc/ssh/sshd_config.d/vision-sftp.conf
run
check "SFTP off: drop-in written all the same (ingest + SMB accounts locked out)" "$(grep -c '^Match User aoiftp,smbuser$' "$DROP")" 1
check "  ... with no SFTP block" "$(grep -c 'LocalAddress' "$DROP")" 0
run "SFTP_ENABLED=true" "ETH1_ADDRESS=192.168.77.1"
check "SFTP on: allowed only on eth1's address" "$(grep -c '^Match User aoiftp LocalAddress 192.168.77.1$' "$DROP")" 1
check "  ... ahead of the lock-out block (first match wins)" \
  "$(grep -n '^Match' "$DROP" | cut -d: -f1 | tr '\n' ' ')" "2 6 "
run "INGEST_ENABLED=false" "SFTP_ENABLED=true"
check "ingest off: no SFTP block, lock-out kept" "$(grep -c 'LocalAddress' "$DROP"):$(grep -c '^Match User aoiftp,smbuser$' "$DROP")" "0:1"

echo "=== eth1: duplicate address detection, and a refused address is reported ==="
echo 0 > "$TMP/up_rc"; : > "$TMP/nmlog"
run "ETH1_ENABLED=true" "ETH1_INTERFACE=lo"
check "eth1 profile asks NetworkManager for duplicate address detection" \
  "$(grep -c 'connection modify --temporary vision-lo .*ipv4.dad-timeout 1000' "$TMP/calls")" 1
check "  ... and comes up: success" "$(grep -c '^rc=' "$TMP/out")" 0
echo 4 > "$TMP/up_rc"
echo "l3cfg[x,ifindex=1]: IPv4 address 192.168.100.1 is used on network connected to interface 1 (lo) from host AA:BB:CC:00:11:22" > "$TMP/nmlog"
run "ETH1_ENABLED=true" "ETH1_INTERFACE=lo"
check "address taken on the cable: the apply fails" "$(grep -c '^rc=1$' "$TMP/out")" 1
check "  ... and says why, naming the other host" "$(grep -c 'already used by another host (AA:BB:CC:00:11:22) on the cable in lo' "$TMP/out")" 1
check "  ... FTP still configured" "$(grep -c 'ingest configured' "$TMP/out")" 1
: > "$TMP/nmlog"
run "ETH1_ENABLED=true" "ETH1_INTERFACE=lo"
check "other activation failure with a cable in: fails, with nmcli's reason" "$(grep -c 'has a cable but did not come up' "$TMP/out"):$(grep -c '^rc=1$' "$TMP/out")" "1:1"
run "ETH1_ENABLED=true" "ETH1_INTERFACE=tst0"
check "no cable: not a failure (comes up on carrier)" "$(grep -c 'will activate on carrier' "$TMP/out"):$(grep -c '^rc=' "$TMP/out")" "1:0"

echo "=== eth1: no re-activation when nothing changed (every Save + Apply runs this) ==="
echo 0 > "$TMP/up_rc"; echo "vision-lo:lo" > "$TMP/active"
echo "192.168.100.1/24" > "$TMP/settings_1"; echo "192.168.100.1/24" > "$TMP/settings_2"; rm -f "$TMP/greads"
run "ETH1_ENABLED=true" "ETH1_INTERFACE=lo"
check "active with the same settings -> left alone (it cut the address for ~0.7 s)" "$(grep -c 'connection up' "$TMP/calls")" 0
echo "192.168.100.2/24" > "$TMP/settings_2"; rm -f "$TMP/greads"
run "ETH1_ENABLED=true" "ETH1_INTERFACE=lo"
check "settings changed -> re-activated" "$(grep -c 'connection up vision-lo' "$TMP/calls")" 1
echo "192.168.100.1/24" > "$TMP/settings_2"; : > "$TMP/active"; rm -f "$TMP/greads"
run "ETH1_ENABLED=true" "ETH1_INTERFACE=lo"
check "same settings but not active (no cable earlier, or refused) -> activated" "$(grep -c 'connection up vision-lo' "$TMP/calls")" 1
rm -f "$TMP/settings_1" "$TMP/settings_2" "$TMP/greads"

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"

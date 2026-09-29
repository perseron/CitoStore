#!/usr/bin/env bash
set -euo pipefail

# lan-rebind.sh must restart samba exactly when smbd is not listening on an
# address its interface now has — the direct 1-1 link case, where 10.10.10.1
# appears ~20s after smbd started and port 445 stayed closed — and must NOT
# restart it otherwise (a DHCP renewal that keeps the address would drop every
# connected client). Same for the mirror FTP's captured listen_address.
#
# ip / ss / systemctl are stubbed on PATH so each case controls the interface
# addresses, the listening sockets and smbd's state, and every systemctl call is
# recorded. Needs root only because lan-rebind.sh insists on it (run it in a
# throwaway container: docker run --rm -v "$PWD:/gw" debian:bookworm-slim
# bash /gw/tests/functional/test_lan_rebind.sh).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)

if [[ $(id -u) -ne 0 ]]; then
  echo "must run as root (lan-rebind.sh requires it)" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/bin"
mkdir -p "$STUB" "$TMP/gw/install"

cat > "$STUB/ip" <<EOF
#!/bin/bash
# ip -4 -o addr show dev <iface>
dev="\${@: -1}"
[[ -f "$TMP/addr.\$dev" ]] || exit 0
while read -r a; do
  [[ -n "\$a" ]] && echo "2: \$dev    inet \$a/24 brd 10.10.10.255 scope global \$dev\\       valid_lft forever preferred_lft forever"
done < "$TMP/addr.\$dev"
EOF
cat > "$STUB/ss" <<EOF
#!/bin/bash
cat "$TMP/ss.out" 2>/dev/null || true
EOF
cat > "$STUB/systemctl" <<EOF
#!/bin/bash
if [[ "\$1" == "is-active" ]]; then
  [[ -f "$TMP/smbd.active" ]]
  exit
fi
echo "systemctl \$*" >> "$TMP/calls"
EOF
# The mirror FTP applier is replaced by a recorder via GATEWAY_HOME.
cat > "$TMP/gw/install/80_configure_mirror_ftp.sh" <<EOF
#!/bin/bash
echo "80_configure_mirror_ftp" >> "$TMP/calls"
EOF
chmod +x "$STUB"/* "$TMP/gw/install/80_configure_mirror_ftp.sh"

MIRROR_CONF=/etc/vsftpd-mirror.conf
MIRROR_CONF_BACKUP=""
if [[ -f "$MIRROR_CONF" ]]; then
  MIRROR_CONF_BACKUP="$TMP/vsftpd-mirror.conf.orig"
  cp "$MIRROR_CONF" "$MIRROR_CONF_BACKUP"
fi
restore_mirror_conf() {
  if [[ -n "$MIRROR_CONF_BACKUP" ]]; then cp "$MIRROR_CONF_BACKUP" "$MIRROR_CONF"; else rm -f "$MIRROR_CONF"; fi
}
trap 'restore_mirror_conf; rm -rf "$TMP"' EXIT

# One case = fresh state, run, return the recorded calls (one line each).
run_case() {  # <iface> <action> <ftp_enabled>
  rm -f "$TMP/calls"
  cat > "$TMP/vision-gw.conf" <<EOF
SMB_BIND_INTERFACE=eth0
MIRROR_FTP_ENABLED=$3
MIRROR_FTP_BIND_INTERFACE=eth0
EOF
  PATH="$STUB:$PATH" CONF_FILE="$TMP/vision-gw.conf" GATEWAY_HOME="$TMP/gw" \
    bash "$GW/scripts/lan-rebind.sh" "$1" "$2" >/dev/null 2>&1 || echo "EXIT $?" >> "$TMP/calls"
  cat "$TMP/calls" 2>/dev/null | tr '\n' ';' || true
}

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }
RESTART="systemctl --no-block restart nmbd.service smbd.service;"

echo "=== samba ==="
echo "10.10.10.1" > "$TMP/addr.eth0"
touch "$TMP/smbd.active"
printf '%s\n' "LISTEN 0 50 127.0.0.1:445 0.0.0.0:*" "LISTEN 0 50 [::1]:445 [::]:*" > "$TMP/ss.out"
check "direct-link address appeared after smbd started -> restart" "$(run_case eth0 up false)" "$RESTART"
check "dhcp4-change with the address missing -> restart" "$(run_case eth0 dhcp4-change false)" "$RESTART"

printf '%s\n' "LISTEN 0 50 127.0.0.1:445 0.0.0.0:*" "LISTEN 0 50 10.10.10.1:445 0.0.0.0:*" > "$TMP/ss.out"
check "already listening on the address -> no restart (renewal keeps clients)" "$(run_case eth0 dhcp4-change false)" ""

printf '%s\n' "LISTEN 0 50 10.10.10.12:445 0.0.0.0:*" > "$TMP/ss.out"
check "10.10.10.12 does not count as 10.10.10.1 -> restart" "$(run_case eth0 up false)" "$RESTART"

printf '%s\n' "LISTEN 0 50 0.0.0.0:445 0.0.0.0:*" > "$TMP/ss.out"
check "wildcard 0.0.0.0 listener covers every address -> no restart" "$(run_case eth0 up false)" ""

printf '%s\n' "LISTEN 0 50 127.0.0.1:445 0.0.0.0:*" > "$TMP/ss.out"
printf '%s\n' "192.168.1.50" "10.10.10.1" > "$TMP/addr.eth0"
check "second address on the interface missing -> restart" "$(run_case eth0 up false)" "$RESTART"
echo "10.10.10.1" > "$TMP/addr.eth0"

check "down event -> nothing" "$(run_case eth0 down false)" ""
check "pre-up event -> nothing" "$(run_case eth0 pre-up false)" ""
echo "192.168.100.1" > "$TMP/addr.eth1"
check "eth1 (not the SMB interface) -> nothing" "$(run_case eth1 up false)" ""

rm -f "$TMP/smbd.active"
check "smbd not running (it will bind at its own start) -> no restart" "$(run_case eth0 up false)" ""
touch "$TMP/smbd.active"

: > "$TMP/addr.eth0"
check "interface has no IPv4 yet -> nothing" "$(run_case eth0 up false)" ""
echo "10.10.10.1" > "$TMP/addr.eth0"

echo "=== mirror FTP ==="
printf '%s\n' "LISTEN 0 50 10.10.10.1:445 0.0.0.0:*" > "$TMP/ss.out"
printf 'listen=YES\nlisten_address=0.0.0.0\n' > "$MIRROR_CONF"
check "bound to 0.0.0.0 (no address at config time) -> reconfigure" "$(run_case eth0 up true)" "80_configure_mirror_ftp;"
printf 'listen=YES\nlisten_address=192.168.2.101\n' > "$MIRROR_CONF"
check "bound to an old DHCP address -> reconfigure" "$(run_case eth0 dhcp4-change true)" "80_configure_mirror_ftp;"
printf 'listen=YES\nlisten_address=10.10.10.1\n' > "$MIRROR_CONF"
check "bound to the current address -> nothing" "$(run_case eth0 up true)" ""
printf 'listen=YES\nlisten_address=0.0.0.0\n' > "$MIRROR_CONF"
check "mirror FTP disabled -> never touched" "$(run_case eth0 up false)" ""

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"

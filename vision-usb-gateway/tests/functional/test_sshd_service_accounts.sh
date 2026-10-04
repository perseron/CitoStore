#!/usr/bin/env bash
set -euo pipefail

# The service accounts (ingest FTP_USER, SMB_USER) have passwords — factory
# default "citostore" — and a nologin shell, which does not stop SSH: as either,
# `ssh -N -L` opened port forwards from the LAN into the AOI network, and the
# AOI's SFTP login worked on eth0 as well (both seen live). The sshd drop-in
# (render_sshd_service_accounts, common.sh) must give them no SSH login and no
# forwarding, except the AOI's SFTP on the eth1 address — and leave the admin
# account alone. Evaluated by sshd itself (sshd -T -C, the Match engine), on
# Debian bookworm's OpenSSH like the unit's:
#   docker run --rm -v "$PWD:/gw:ro" debian:bookworm bash /gw/tests/functional/test_sshd_service_accounts.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)

if ! command -v sshd >/dev/null 2>&1; then
  apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null
fi
mkdir -p /run/sshd
ssh-keygen -A >/dev/null
for u in aoiftp smbuser citostore; do id "$u" >/dev/null 2>&1 || useradd -M "$u"; done

# shellcheck source=/dev/null
source "$GW/scripts/common.sh"

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

DROPIN=/etc/ssh/sshd_config.d/vision-sftp.conf
eff() {  # <user> <local address> <keyword>
  sshd -T -C "user=$1,host=client,addr=10.10.10.60,laddr=$2,lport=22" 2>/dev/null | awk -v k="$3" '$1==k{$1=""; sub(/^ /,""); print}'
}

echo "=== SFTP enabled (AOI on eth1 = 192.168.100.1) ==="
render_sshd_service_accounts aoiftp smbuser /srv/vision_mirror/ingest 192.168.100.1 > "$DROPIN"
check "sshd accepts the drop-in" "$(sshd -t 2>&1 && echo ok)" "ok"
check "AOI SFTP on eth1: password login" "$(eff aoiftp 192.168.100.1 passwordauthentication)" "yes"
check "  ... chrooted into the ingest dir" "$(eff aoiftp 192.168.100.1 chrootdirectory)" "/srv/vision_mirror/ingest"
check "  ... SFTP only" "$(eff aoiftp 192.168.100.1 forcecommand)" "internal-sftp -d /data"
check "  ... no forwarding" "$(eff aoiftp 192.168.100.1 disableforwarding)" "yes"
check "ingest account on eth0 (the LAN): no password login" "$(eff aoiftp 10.10.10.1 passwordauthentication)" "no"
check "  ... no key login either" "$(eff aoiftp 10.10.10.1 pubkeyauthentication)" "no"
check "SMB account: no password login" "$(eff smbuser 10.10.10.1 passwordauthentication)" "no"
check "  ... not on eth1 either" "$(eff smbuser 192.168.100.1 passwordauthentication)" "no"
check "  ... no forwarding" "$(eff smbuser 10.10.10.1 disableforwarding)" "yes"
check "admin account untouched: password per the global config" "$(eff citostore 10.10.10.1 passwordauthentication)" "yes"
check "  ... keys" "$(eff citostore 10.10.10.1 pubkeyauthentication)" "yes"
check "  ... forwarding" "$(eff citostore 10.10.10.1 disableforwarding)" "no"
check "  ... no forced command" "$(eff citostore 192.168.100.1 forcecommand)" "none"

echo "=== SFTP disabled (FTP only, or ingest off) ==="
render_sshd_service_accounts aoiftp smbuser /srv/vision_mirror/ingest > "$DROPIN"
check "sshd accepts the drop-in" "$(sshd -t 2>&1 && echo ok)" "ok"
check "ingest account on eth1: no SSH login (it has a password for FTP)" "$(eff aoiftp 192.168.100.1 passwordauthentication)" "no"
check "  ... no forwarding" "$(eff aoiftp 192.168.100.1 disableforwarding)" "yes"
check "admin account untouched" "$(eff citostore 10.10.10.1 passwordauthentication)" "yes"

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"

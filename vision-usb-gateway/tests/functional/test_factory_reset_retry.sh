#!/usr/bin/env bash
set -euo pipefail

# A factory-reset rebuild cut short (power cut during the heavy NVMe work) left
# a half-built NVMe and nothing to finish it. It is retried at the next boots,
# a bounded number of times (never a boot loop). Disk tools and 30_setup are
# stubbed; the marker logic is real. Root, in a throwaway container:
#   docker run --rm -v "$PWD:/gw:ro" debian:bookworm bash /gw/tests/functional/test_factory_reset_retry.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 && -f /.dockerenv ]] || { echo "run as root in a container (writes /boot/firmware)" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" /boot/firmware/factory-reset-*' EXIT
FAKE=$TMP/gw; B=$TMP/bin
mkdir -p "$FAKE/scripts" "$FAKE/install" "$B" /boot/firmware "$TMP/mirror"
tr -d '\r' < "$GW/scripts/common.sh" > "$FAKE/scripts/common.sh"
tr -d '\r' < "$GW/scripts/factory-reset.sh" > "$FAKE/scripts/factory-reset.sh"
printf '#!/bin/bash\necho "30_setup $*" >> %s/calls\nexit $(cat %s/setup_rc)\n' "$TMP" "$TMP" > "$FAKE/install/30_setup_nvme_lvm.sh"
chmod +x "$FAKE/install/30_setup_nvme_lvm.sh"
printf 'GATEWAY_HOME=%s\nMIRROR_MOUNT=%s\n' "$FAKE" "$TMP/mirror" > /etc/vision-gw.conf
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$B/$1"; chmod +x "$B/$1"; }
stub systemctl 'echo "systemctl $*" >> '"$TMP"'/calls'
stub mountpoint '[[ "$*" == *mirror* ]]'
stub findmnt 'echo /dev/mmcblk0p2'
for c in umount mount vgchange udevadm; do stub "$c" 'exit 0'; done
export PATH="$B:$PATH" GATEWAY_HOME=$FAKE

boot() { : > "$TMP/calls"; bash "$FAKE/scripts/factory-reset.sh" --boot >"$TMP/out" 2>&1 && echo rc=0 || echo "rc=$?"; }
state() { echo "$(test -e /boot/firmware/factory-reset-pending && echo P)$(cat /boot/firmware/factory-reset-in-progress 2>/dev/null)"; }

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

check "nothing armed: nothing done" "$(boot):$(cat "$TMP/calls")" "rc=0:"
touch /boot/firmware/factory-reset-pending; echo 1 > "$TMP/setup_rc"
check "armed, the rebuild fails (power cut): armed marker gone, attempt 1 recorded" "$(boot | cut -c1-4):$(state)" "rc=1:1"
echo 0 > "$TMP/setup_rc"
check "next boot: retried and finished, then a clean reboot" "$(boot):$(state):$(grep -c 'systemctl reboot' "$TMP/calls")" "rc=0::1"
echo 3 > /boot/firmware/factory-reset-in-progress
check "after 3 failed attempts: gives up, no boot loop" "$(boot | cut -c1-4):$(state):$(grep -c 30_setup "$TMP/calls")" "rc=1::0"

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"

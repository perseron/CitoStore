#!/usr/bin/env bash
set -euo pipefail

# Wipe All Data keeps the unit's settings — with the mirror's mount modelled
# for real: once srv-vision_mirror.mount is stopped, .state is NOT readable at
# the mount point any more (the bug seen live 2026-10-01: the backup ran after
# the unmount and saved nothing). LVM/mkfs/systemd stubbed, in a container:
#   docker run --rm -v "$PWD:/src:ro" debian:bookworm bash -c \
#     'cp -r /src /gw && bash /gw/tests/functional/test_wipe.sh'
# It writes to /etc, /run and /mnt, so never run it on a real unit.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 ]] || { echo "run as root in a container" >&2; exit 1; }
[[ -f /.dockerenv ]] || { echo "refusing to run outside a container" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

FAKE=$TMP/gw
mkdir -p "$FAKE/scripts"
for f in common.sh wipe-all-data.sh; do tr -d '\r' < "$GW/scripts/$f" > "$FAKE/scripts/$f"; done
mkdir -p "$FAKE/install"
printf '#!/bin/bash\necho ran-70 >> %s/calls\n' "$TMP" > "$FAKE/install/70_configure_ingest.sh"

# The mirror filesystem lives in $TMP/fs while unmounted; mounted, it IS $M.
M=$TMP/mirror
mkdir -p "$TMP/bin"
cat > "$TMP/bin/fsctl" <<EOF
#!/bin/bash
case "\$1" in
  umount) [[ -f $TMP/mounted ]] || exit 0; mv "$M" "$TMP/fs"; mkdir -p "$M"; rm -f $TMP/mounted ;;
  mount)  [[ -f $TMP/mounted ]] && exit 0; rm -rf "$M"; mv "$TMP/fs" "$M"; touch $TMP/mounted ;;
esac
EOF
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }
stub systemctl "echo \"systemctl \$*\" >> $TMP/calls
case \"\$*\" in
  *stop*srv-vision_mirror.mount*) $TMP/bin/fsctl umount ;;
  start*srv-vision_mirror.mount*|start*vision-webui*) $TMP/bin/fsctl mount ;;
esac
exit 0"
stub mountpoint "[[ \"\${@: -1}\" == \"$M\" && -f $TMP/mounted ]]"
stub umount "[[ \"\${@: -1}\" == \"$M\" ]] && $TMP/bin/fsctl umount; exit 0"
stub mount "if [[ \"\$*\" == *vfat* ]]; then exit 0; fi; [[ -f $TMP/fail_mount ]] && exit 32; $TMP/bin/fsctl mount"
stub mkfs.ext4 "[[ -f $TMP/mounted ]] && { echo 'in use' >&2; exit 1; }; rm -rf $TMP/fs; mkdir -p $TMP/fs; echo mkfs.ext4 >> $TMP/calls"
stub mkfs.vfat "echo \"mkfs.vfat \$*\" >> $TMP/calls"
stub vgchange "exit 0"
stub sfdisk "exit 0"
stub fuser "exit 0"
chmod +x "$TMP/bin/fsctl"
export PATH="$TMP/bin:$PATH"
export GATEWAY_HOME=$FAKE

printf 'GATEWAY_HOME=%s\nMIRROR_MOUNT=%s\nLVM_VG=vg0\nUSB_LVS=(usb_0 usb_1)\nINGEST_DIR=%s/ingest\n' "$FAKE" "$M" "$M" > /etc/vision-gw.conf
unit_with_data() {
  rm -rf "$M" "$TMP/fs" "$TMP/mounted" /mnt/vision_wipe_*
  mkdir -p "$M/.state/samba/private" "$M/.state/aoi_settings" "$M/.state/updates" "$M/raw/2026" "$M/bydate"
  cp /etc/vision-gw.conf "$M/.state/vision-gw.conf"
  echo pw > "$M/.state/webui.passwd"; echo sec > "$M/.state/webui.secret"
  echo '{"method":"manual"}' > "$M/.state/network.json"
  echo smbusers > "$M/.state/samba/private/passdb.tdb"
  echo ftp > "$M/.state/ftp.creds"; echo recipe > "$M/.state/aoi_settings/r.ini"
  echo img > "$M/raw/2026/a.bmp"
  mkdir -p "$M/ingest/data" "$M/ingest/aoi_settings"
  echo eth-aoi > "$M/ingest/aoi_settings/line.cfg"; echo upload > "$M/ingest/data/u.bmp"
  touch "$TMP/mounted"
  : > "$TMP/calls"
}
wipe() {
  local rc=0
  bash "$FAKE/scripts/wipe-all-data.sh" --i-know-what-im-doing --force-umount >"$TMP/out" 2>&1 || rc=$?
  echo "$rc"
}
st() { cat "$M/.state/$1" 2>/dev/null || echo MISSING; }

echo "=== a wipe keeps every setting (backup taken while the mirror is mounted) ==="
unit_with_data
check "wipe succeeds" "$(wipe)" 0
check "the mirror really was reformatted" "$(grep -c '^mkfs.ext4$' "$TMP/calls")" 1
check "images gone" "$(find "$M/raw" -type f | wc -l)" 0
check "WebUI password kept (else /setup is open)" "$(st webui.passwd)" pw
check "session secret kept" "$(st webui.secret)" sec
check "network setting kept" "$(st network.json)" '{"method":"manual"}'
check "SMB users kept" "$(st samba/private/passdb.tdb)" smbusers
check "FTP password kept" "$(st ftp.creds)" ftp
check "AOI settings kept" "$(st aoi_settings/r.ini)" recipe
check "AOI settings pushed onto the new USB drive" "$(cat /mnt/vision_wipe_usb_1/aoi_settings/r.ini 2>/dev/null)" recipe
check "Samba bind restarted before smbd" "$(grep -n -e 'start var-lib-samba.mount' -e 'start smbd' "$TMP/calls" | head -1 | grep -c var-lib-samba)" 1
check "fast-sync timer stopped too" "$(grep -c 'stop .*vision-sync-fast.timer' "$TMP/calls")" 1
check "the Ethernet AOI's settings kept" "$(cat "$M/ingest/aoi_settings/line.cfg" 2>/dev/null)" eth-aoi
check "  ... its uploads wiped like the images" "$(test -e "$M/ingest/data/u.bmp" && echo kept || echo gone)" gone
check "  ... and the FTP root re-created right away (70 re-run)" "$(grep -c '^ran-70$' "$TMP/calls")" 1

echo "=== no mirror mounted: nothing to back up, so nothing is wiped ==="
unit_with_data
"$TMP/bin/fsctl" umount
check "wipe refuses" "$(wipe)" 1
check "  ... no mkfs" "$(grep -c mkfs "$TMP/calls")" 0
check "  ... says why" "$(grep -c 'cannot be backed up' "$TMP/out")" 1
check "  ... and restarts what it stopped" "$(grep -c 'start usb-gadget.service' "$TMP/calls")" 1

echo "=== failure after the reformat: settings put back before the stack starts ==="
unit_with_data
touch "$TMP/fail_mount"
rc=$(wipe); check "wipe fails (mount after mkfs fails)" "$([[ $rc -ne 0 ]] && echo failed || echo ok)" failed
rm -f "$TMP/fail_mount"
check "  WebUI password restored by the failure path" "$(st webui.passwd)" pw
check "  SMB users restored" "$(st samba/private/passdb.tdb)" smbusers

echo "=== the sync's ExecStopPost never waits on its own timer ==="
check "vision-monitor toggles the fast timer with --no-block" \
  "$(tr -d '\r' < "$GW/scripts/vision-monitor.sh" | grep -E 'systemctl .*(start|stop) "\$FAST_SYNC_TIMER"' | grep -vc -- '--no-block')" 0

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"

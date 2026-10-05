#!/usr/bin/env bash
set -euo pipefail

# Audit batch 3 (2026-10-01): config persistence + storage maintenance, run
# against the real scripts with LVM/systemd stubbed, in a throwaway container:
#   docker run --rm -v "$PWD:/src:ro" debian:bookworm bash -c \
#     'cp -r /src /gw && bash /gw/tests/functional/test_audit_batch3.sh'
# It writes to /etc, /srv, /mnt and /media, so never run it on a real unit.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 ]] || { echo "run as root in a container" >&2; exit 1; }
[[ -f /.dockerenv ]] || { echo "refusing to run outside a container" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

# A fake install: the real scripts under test, stubs for what they call.
FAKE=$TMP/gw
mkdir -p "$FAKE/scripts" "$FAKE/install" "$FAKE/conf"
for f in common.sh resize-usb-lvs.sh restore-defaults.sh; do
  tr -d '\r' < "$GW/scripts/$f" > "$FAKE/scripts/$f"
done
tr -d '\r' < "$GW/conf/vision-gw.conf.example" > "$FAKE/conf/vision-gw.conf.example"
printf '#!/bin/bash\necho apply >> %s/calls\n' "$TMP" > "$FAKE/scripts/apply-shadow-config.sh"
printf '#!/bin/bash\necho "switch $*" >> %s/calls\n' "$TMP" > "$FAKE/scripts/usb-gadget.sh"
printf '#!/bin/bash\necho selfheal >> %s/calls\n' "$TMP" > "$FAKE/install/30_setup_nvme_lvm.sh"
chmod +x "$FAKE"/scripts/*.sh "$FAKE"/install/*.sh

mkdir -p "$TMP/bin"
stub() {  # <name> <body>
  printf '#!/bin/bash\n%s\n' "$2" > "$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}
# lvs: the pool size for "-o lv_size", "exists" for a plain LV query.
stub lvs "if [[ \"\$*\" == *lv_size* ]]; then echo \"  \$(cat $TMP/pool_bytes).00\"; else exit 0; fi"
stub lvremove "echo \"lvremove \$*\" >> $TMP/calls"
stub lvcreate "echo \"lvcreate \$*\" >> $TMP/calls"
stub mkfs.vfat "echo \"mkfs \$*\" >> $TMP/calls"
stub mount "exit 0"
stub umount "exit 0"
stub mountpoint "[[ -f $TMP/mounted ]]"
stub systemctl "echo \"systemctl \$*\" >> $TMP/calls
case \"\$1\" in
  is-active) [[ \"\$*\" == *vision-sync.timer* ]] ;;
  show) echo inactive ;;
  start) [[ \"\$*\" == *vision-sync.service* && -f $TMP/sync_fails ]] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac"
# The offline export of each LV before it goes (anything else: the real python3).
stub python3 "if [[ \"\$1 \$2\" == \"-m vision_sync.sync\" ]]; then echo \"export \${@: -2:1}\" >> $TMP/calls; exit 0; fi; exec /usr/bin/python3 \"\$@\""
export PATH="$TMP/bin:$PATH"
export GATEWAY_HOME=$FAKE

MIRROR=/srv/vision_mirror
mkdir -p "$MIRROR/.state/aoi_settings"
echo "aoi-recipe" > "$MIRROR/.state/aoi_settings/recipe.ini"
base_conf() {
  printf 'GATEWAY_HOME=%s\nLVM_VG=vg0\nTHINPOOL_LV=usbpool\nUSB_LVS=(usb_0 usb_1 usb_2)\nUSB_LV_SIZE=16G\nRETENTION_HI=90\n' "$FAKE" \
    | tee /etc/vision-gw.conf > "$MIRROR/.state/vision-gw.conf"
}
resize() {  # <size> -> exit code
  : > "$TMP/calls"
  local rc=0
  bash "$FAKE/scripts/resize-usb-lvs.sh" --size "$1" --force --update-config >"$TMP/out" 2>&1 || rc=$?
  echo "$rc"
}
removed() { grep -c '^lvremove' "$TMP/calls" || true; }

echo "=== set_conf_value: shadow AND /etc, /etc keeps its inode ==="
base_conf
ino=$(stat -c %i /etc/vision-gw.conf)
( source "$FAKE/scripts/common.sh"; set_conf_value USB_LV_SIZE 8G; set_conf_value NEW_KEY 1 )
check "shadow updated" "$(grep -c '^USB_LV_SIZE=8G$' "$MIRROR/.state/vision-gw.conf")" 1
check "/etc updated" "$(grep -c '^USB_LV_SIZE=8G$' /etc/vision-gw.conf)" 1
check "missing key appended" "$(grep -c '^NEW_KEY=1$' "$MIRROR/.state/vision-gw.conf")" 1
check "other keys untouched" "$(grep -c '^RETENTION_HI=90$' "$MIRROR/.state/vision-gw.conf")" 1
check "no duplicate key" "$(grep -c '^USB_LV_SIZE=' /etc/vision-gw.conf)" 1
check "/etc rewritten in place (the WebUI sandbox binds this inode)" "$(stat -c %i /etc/vision-gw.conf)" "$ino"

echo "=== restore_shadow_conf: /etc in place, and left alone when nothing changed ==="
base_conf
ino=$(stat -c %i /etc/vision-gw.conf)
( source "$FAKE/scripts/common.sh"; restore_shadow_conf )
check "same inode (the WebUI sandbox binds it; sed -i swapped it)" "$(stat -c %i /etc/vision-gw.conf)" "$ino"
check "GATEWAY_HOME re-asserted" "$(grep -c "^GATEWAY_HOME=$FAKE$" /etc/vision-gw.conf)" 1
touch -d '2001-01-01' /etc/vision-gw.conf
( source "$FAKE/scripts/common.sh"; restore_shadow_conf )
check "unchanged config: not rewritten (no truncated moment for readers)" "$(stat -c %Y /etc/vision-gw.conf)" "$(date -d 2001-01-01 +%s)"
echo "NETBIOS_NAME=NEW1" >> "$MIRROR/.state/vision-gw.conf"
( source "$FAKE/scripts/common.sh"; restore_shadow_conf )
check "a changed shadow is written over it" "$(grep -c '^NETBIOS_NAME=NEW1$' /etc/vision-gw.conf):$(stat -c %i /etc/vision-gw.conf)" "1:$ino"

echo "=== golden_conf: seed > overlay lower > generic example ==="
rm -f /etc/citostore-seed/vision-gw.conf /media/root-ro/etc/vision-gw.conf
g() { ( source "$FAKE/scripts/common.sh"; golden_conf ); }
check "nothing else: the example" "$(g)" "$FAKE/conf/vision-gw.conf.example"
mkdir -p /media/root-ro/etc && echo "NETBIOS_NAME=AOI1" > /media/root-ro/etc/vision-gw.conf
check "overlay lower /etc preferred" "$(g)" /media/root-ro/etc/vision-gw.conf
mkdir -p /etc/citostore-seed && printf 'GATEWAY_HOME=/old\nNETBIOS_NAME=AOI1\nUSB_LV_SIZE=16G\n' > /etc/citostore-seed/vision-gw.conf
check "seed copy preferred" "$(g)" /etc/citostore-seed/vision-gw.conf

echo "=== restore-defaults: the unit's factory config, applied ==="
base_conf
echo "NETBIOS_NAME=CHANGED" >> "$MIRROR/.state/vision-gw.conf"
rm -f "$TMP/mounted"; : > "$TMP/calls"
rc=0; bash "$FAKE/scripts/restore-defaults.sh" --i-know-what-im-doing >"$TMP/out" 2>&1 || rc=$?
check "mirror not mounted: refused" "$rc" 1
check "  ... shadow untouched" "$(grep -c CHANGED "$MIRROR/.state/vision-gw.conf")" 1
touch "$TMP/mounted"; : > "$TMP/calls"
rc=0; bash "$FAKE/scripts/restore-defaults.sh" --i-know-what-im-doing >"$TMP/out" 2>&1 || rc=$?
check "succeeds" "$rc" 0
check "shadow = factory config (not the generic example)" "$(grep -c '^NETBIOS_NAME=AOI1$' "$MIRROR/.state/vision-gw.conf")" 1
check "  ... with this install's GATEWAY_HOME" "$(grep -c "^GATEWAY_HOME=$FAKE$" "$MIRROR/.state/vision-gw.conf")" 1
check "applied right away" "$(grep -c '^apply$' "$TMP/calls")" 1
check "no temp file left" "$(find "$MIRROR/.state" -name 'vision-gw.conf.*' ! -name '*.last-good' | wc -l)" 0

echo "=== resize: refused sizes change nothing ==="
base_conf
echo 68719476736 > "$TMP/pool_bytes"   # 64G pool
for bad in 4GB 0G 1.5G 100 '4G;reboot' 32M; do
  check "size '$bad' refused" "$(resize "$bad")" 1
  check "  ... nothing removed" "$(removed)" 0
done
check "3 x 32G in a 64G pool refused (over-commit)" "$(resize 32G)" 1
check "  ... nothing removed" "$(removed)" 0
check "  ... and says why" "$(grep -c 'does not fit the USB pool' "$TMP/out")" 1
touch "$TMP/sync_fails"
check "sync fails: refused" "$(resize 20G)" 1
check "  ... nothing removed" "$(removed)" 0
check "  ... sync timer put back" "$(grep -c 'systemctl start vision-sync.timer' "$TMP/calls")" 1
rm -f "$TMP/sync_fails"

echo "=== resize: a valid size ==="
check "3 x 20G in a 64G pool accepted" "$(resize 20g)" 0
check "every LV recreated at 20G" "$(grep -c 'lvcreate -V 20G' "$TMP/calls")" 3
check "synced before the first removal" "$(grep -n -m1 -e 'start vision-sync.service' -e '^lvremove' "$TMP/calls" | cut -d: -f2- | cut -d' ' -f1-2)" "systemctl start"
check "FAT32 with a volume serial" "$(grep -c 'mkfs -F 32 -n VISIONUSB -i ' "$TMP/calls")" 3
check "AOI settings put back on the new LV" "$(cat /mnt/vision_resize_usb_2/aoi_settings/recipe.ini 2>/dev/null)" aoi-recipe
check "new size in the shadow (survives the reboot)" "$(grep -c '^USB_LV_SIZE=20G$' "$MIRROR/.state/vision-gw.conf")" 1
check "  ... and in /etc" "$(grep -c '^USB_LV_SIZE=20G$' /etc/vision-gw.conf)" 1
check "sync timer restarted" "$(grep -c 'systemctl start vision-sync.timer' "$TMP/calls")" 1
check "no self-heal needed" "$(grep -c selfheal "$TMP/calls")" 0
check "each LV exported in full before it is removed" "$(grep -E "^(export|lvremove)" "$TMP/calls" | cut -d" " -f1 | paste -sd" ")" "export lvremove export lvremove export lvremove"

echo "=== resize: an LV that cannot be removed ==="
base_conf
stub lvremove "echo \"lvremove \$*\" >> $TMP/calls; exit 5"
check "fails" "$(resize 20G)" 1
check "  ... says which LV" "$(grep -c 'cannot remove /dev/vg0/usb_0' "$TMP/out")" 1
check "  ... no lvcreate over it" "$(grep -c '^lvcreate' "$TMP/calls")" 0
check "  ... missing LVs self-healed" "$(grep -c selfheal "$TMP/calls")" 1
check "  ... config keeps the old size" "$(grep -c '^USB_LV_SIZE=16G$' "$MIRROR/.state/vision-gw.conf")" 1

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"

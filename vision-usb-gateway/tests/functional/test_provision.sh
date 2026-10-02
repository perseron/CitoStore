#!/usr/bin/env bash
set -euo pipefail

# provision-from-bundle.sh: the reuse path (keep the NVMe layout, never tear
# down a mounted mirror) and the wipe path (only a disk with nothing mounted),
# with LVM/systemd stubbed, in a throwaway container:
#   docker run --rm -v "$PWD:/src:ro" python:3.11-slim-bookworm bash -c \
#     'cp -r /src /gw && bash /gw/tests/functional/test_provision.sh'
# It writes to /etc and /srv, so never run it on a real unit.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 ]] || { echo "run as root in a container" >&2; exit 1; }
[[ -f /.dockerenv ]] || { echo "refusing to run outside a container" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }
G=$((1024 * 1024 * 1024))

FAKE=$TMP/gw
mkdir -p "$FAKE/scripts" "$FAKE/install"
for f in common.sh provision-from-bundle.sh; do tr -d '\r' < "$GW/scripts/$f" > "$FAKE/scripts/$f"; done
printf '#!/bin/bash\necho apply >> %s/calls\n' "$TMP" > "$FAKE/scripts/apply-shadow-config.sh"
printf '#!/bin/bash\necho "gadget $*" >> %s/calls\n' "$TMP" > "$FAKE/scripts/usb-gadget.sh"
printf '#!/bin/bash\necho "30_setup $*" >> %s/calls\n' "$TMP" > "$FAKE/install/30_setup_nvme_lvm.sh"
chmod +x "$FAKE"/scripts/*.sh "$FAKE"/install/*.sh

# LVM model: $TMP/lv/<name> holds the LV size in bytes.
mkdir -p "$TMP/bin" "$TMP/lv"
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }
stub lvs "lv=\${@: -1}; f=$TMP/lv/\${lv#*/}; [[ -f \$f ]] || exit 5
case \"\$*\" in *lv_metadata_size*) echo \"  $G.00\" ;; *lv_size*) echo \"  \$(cat \$f).00\" ;; esac"
stub vgs "echo \"  \$(cat $TMP/vg_free).00\""
stub blockdev "cat $TMP/disk_bytes"
stub mountpoint "[[ -f $TMP/mounted ]]"
stub lsblk "[[ -f $TMP/mounted ]] && echo /srv/vision_mirror; exit 0"
stub lvremove "echo \"lvremove \$*\" >> $TMP/calls"
stub lvextend "echo \"lvextend \$*\" >> $TMP/calls"
stub vgchange "echo \"vgchange \$*\" >> $TMP/calls"
stub dmsetup "exit 0"
stub mount "touch $TMP/mounted"
stub smbpasswd "exit 0"
stub systemctl "echo \"systemctl \$*\" >> $TMP/calls; [[ \$1 == show ]] && echo inactive; exit 0"
export PATH="$TMP/bin:$PATH"

MIRROR=$TMP/mirror
mknod "$TMP/nvme0n1" b 259 0
golden_layout() {  # this unit as its first boot left it: 1 TB, 856G mirror, 64G pool, 3 x 16G
  rm -f "$TMP"/lv/*
  mkdir -p "$MIRROR/.state" && echo "digest=old" > "$MIRROR/.state/usb_persist.manifest"
  echo $((856 * G)) > "$TMP/lv/mirror"; echo $((64 * G)) > "$TMP/lv/usbpool"
  for i in 0 1 2; do echo $((16 * G)) > "$TMP/lv/usb_$i"; done
  echo $((931 * G)) > "$TMP/disk_bytes"; echo $((9 * G)) > "$TMP/vg_free"
  touch "$TMP/mounted"; mkdir -p "$MIRROR/.state"
}
bundle() {  # <USB_LV_SIZE value as written in the config>
  rm -rf "$TMP/b" && mkdir -p "$TMP/b/etc" "$TMP/b/state/aoi_settings" "$TMP/b/network"
  cat > "$TMP/b/etc/vision-gw.conf" <<EOF
GATEWAY_HOME=/opt/x
NVME_DEVICE=$TMP/nvme0n1
LVM_VG=vg0
MIRROR_LV=mirror
THINPOOL_LV=usbpool
MIRROR_MOUNT=$MIRROR
USB_LVS=(usb_0 usb_1 usb_2)
USB_LV_SIZE=$1
NETBIOS_NAME=BUNDLEUNIT
EOF
  echo '{"hash":"x"}' > "$TMP/b/state/webui.passwd"
  echo '{"method":"manual","address":"192.168.2.50"}' > "$TMP/b/network/network.json"
  echo "recipe" > "$TMP/b/state/aoi_settings/recipe.ini"
  tar czf "$TMP/bundle.citostore" -C "$TMP/b" .
}
plan() { bash "$FAKE/scripts/provision-from-bundle.sh" "$TMP/bundle.citostore" --plan 2>"$TMP/err"; }
field() { python3 -c 'import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; print(str(v).lower() if isinstance(v,bool) else v)' "$1"; }
provision() {
  : > "$TMP/calls"
  local rc=0
  bash "$FAKE/scripts/provision-from-bundle.sh" "$TMP/bundle.citostore" --provision --confirm >"$TMP/out" 2>&1 || rc=$?
  echo "$rc"
}

echo "=== reuse: a unit with its layout (every unit after first boot) ==="
golden_layout; bundle 16G
p=$(plan)
check "mode is reuse" "$(field mode <<<"$p")" reuse
check "images kept" "$(field images_kept <<<"$p")" true
check "nothing recreated (same size)" "$(field usb_lvs_recreated <<<"$p")" 0
check "mirror not grown on the same disk" "$(field mirror_grow_gib <<<"$p")" 0
check "plan ok" "$(field ok <<<"$p")" true

bundle 20G
p=$(plan)
check "20G bundle: 3 LVs recreated" "$(field usb_lvs_recreated <<<"$p")" 3
check "  ... 3 x 20G fits the 64G pool" "$(field ok <<<"$p")" true
check "provision succeeds" "$(provision)" 0
check "  never wipes / repartitions" "$(grep -c -- '--wipe' "$TMP/calls")" 0
check "  no VG teardown" "$(grep -c '^vgchange' "$TMP/calls")" 0
check "  mirror never stopped/unmounted" "$(grep -cE 'stop .*(srv-vision_mirror|smbd|vision-webui)' "$TMP/calls")" 0
check "  the 3 LVs removed for recreation" "$(grep -c '^lvremove' "$TMP/calls")" 3
check "  30_setup recreates them (no --wipe)" "$(grep -c '^30_setup $' "$TMP/calls")" 1
check "  gadget stopped before the removal" "$(grep -n -m1 -e 'stop usb-gadget' -e '^lvremove' "$TMP/calls" | head -1 | grep -c 'stop usb-gadget')" 1
check "  bundle settings live" "$(grep -c '^NETBIOS_NAME=BUNDLEUNIT$' /etc/vision-gw.conf)" 1
check "  new USB size in the config" "$(grep -c '^USB_LV_SIZE=20G$' /etc/vision-gw.conf)" 1
check "  this unit's pool size, not the bundle's" "$(grep -c '^THINPOOL_SIZE=64G$' /etc/vision-gw.conf)" 1
check "  shadow config written" "$(grep -c '^NETBIOS_NAME=BUNDLEUNIT$' "$MIRROR/.state/vision-gw.conf")" 1
check "  WebUI password restored" "$(cat "$MIRROR/.state/webui.passwd")" '{"hash":"x"}'
check "  static IP restored" "$(grep -c 192.168.2.50 "$MIRROR/.state/network.json")" 1
check "  AOI settings restored" "$(cat "$MIRROR/.state/aoi_settings/recipe.ini")" recipe
check "  ... pushed onto all 3 USB drives (else the next rotation exports their old copy)" "$(grep -cE 'usb_[0-2]: aoi_settings ' "$TMP/out")" 3
check "  ... old persist manifest dropped" "$(test -e "$MIRROR/.state/usb_persist.manifest" && echo yes || echo no)" no
check "  config applied" "$(grep -c '^apply$' "$TMP/calls")" 1
check "  monitor + retention timers back on" "$(grep -c 'start vision-sync.timer vision-monitor.timer mirror-retention.timer' "$TMP/calls")" 1

echo "=== reuse: the bundle's drives do not fit the pool ==="
golden_layout; bundle 30G
p=$(plan)
check "3 x 30G in a 64G pool, 9G free: refused" "$(field ok <<<"$p")" false
check "  ... with the reason" "$(field error <<<"$p" | grep -c 'do not fit')" 1
check "provision refuses" "$(provision)" 1
check "  ... and touches nothing" "$(grep -cE '^(lvremove|lvextend|30_setup)' "$TMP/calls")" 0
echo $((100 * G)) > "$TMP/vg_free"
p=$(plan)
check "with 100G free: pool grows instead" "$(field ok <<<"$p")" true
check "provision succeeds" "$(provision)" 0
check "  pool grown by 26G" "$(grep -c 'lvextend -L +26G vg0/usbpool' "$TMP/calls")" 1

echo "=== reuse: a larger NVMe than the original ==="
golden_layout; bundle 16G
echo $((1863 * G)) > "$TMP/disk_bytes"; echo $((932 * G)) > "$TMP/vg_free"
p=$(plan)
check "mirror grows into the free space" "$(field mirror_grow_gib <<<"$p")" $((932 - 18))
check "provision succeeds" "$(provision)" 0
check "  online grow with resize2fs (-r)" "$(grep -c "lvextend -r -L +914G vg0/mirror" "$TMP/calls")" 1

echo "=== wipe: only when nothing on the NVMe is mounted ==="
golden_layout; bundle 16G
rm -f "$TMP/lv/mirror" "$TMP/mounted"     # first boot never got the mirror created
p=$(plan)
check "no complete layout: mode wipe" "$(field mode <<<"$p")" wipe
check "  plan ok" "$(field ok <<<"$p")" true
check "provision succeeds" "$(provision)" 0
check "  ... the wipe ran" "$(grep -c '^30_setup --wipe$' "$TMP/calls")" 1
touch "$TMP/mounted"
p=$(plan)
check "something mounted, no reusable layout: refused" "$(field ok <<<"$p")" false
check "provision refuses" "$(provision)" 1
check "  ... no wipe" "$(grep -c -- '--wipe' "$TMP/calls")" 0

echo "=== bundle values stay values ==="
golden_layout; bundle '"16G; touch '"$TMP"'/pwned"'
rc=0; plan >/dev/null || rc=$?
check "an injected size is refused" "$rc" 1
check "  ... and nothing ran" "$(test -e "$TMP/pwned" && echo ran || echo no)" no
bundle 512M
p=$(plan)
check "512M is 0.5 GiB, not 512 GiB (rounded up to 1)" "$(field usb_lv_size_gib <<<"$p")" 1
check "  plan ok" "$(field ok <<<"$p")" true

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"

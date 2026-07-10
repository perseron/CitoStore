#!/usr/bin/env bash
set -euo pipefail

# Per-unit first-boot personalisation for cloned units. Invoked once by
# vision-firstboot.service, before the read-only overlay is active. It:
#   - regenerates machine-id, SSH host keys, and a unique hostname
#   - initialises this unit's own (empty) NVMe if needed
#   - seeds .state with the shared WebUI password and a FRESH session secret
#   - optionally re-enables the read-only overlay, then reboots
# It writes /etc/citostore-firstboot-done and disables itself so it never
# runs twice.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root

DONE_FLAG=/etc/citostore-firstboot-done
SEED_DIR=/etc/citostore-seed
STATE_DIR=/srv/vision_mirror/.state

if [[ -f "$DONE_FLAG" ]]; then
  log "first-boot already done; nothing to do"
  exit 0
fi

load_config
# GATEWAY_HOME comes from common.sh (env override or self-derived).
: "${LVM_VG:=vg0}"
: "${MIRROR_LV:=mirror}"

# 1) Unique machine-id (systemd regenerates from the emptied file, but ensure).
log "regenerating machine-id"
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup >/dev/null 2>&1 || true
if command -v dbus-uuidgen >/dev/null 2>&1; then
  dbus-uuidgen --ensure >/dev/null 2>&1 || true
fi

# 2) Fresh SSH host keys.
log "regenerating SSH host keys"
ssh-keygen -A >/dev/null 2>&1 || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# 3) Unique hostname derived from the CM5 serial.
suffix=$(awk '/Serial/ { s=$3 } END { if (s) print substr(s, length(s)-5) }' /proc/cpuinfo 2>/dev/null || true)
[[ -z "$suffix" ]] && suffix=$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')
newhost="citostore-$suffix"
log "setting hostname $newhost"
hostnamectl set-hostname "$newhost" 2>/dev/null || echo "$newhost" > /etc/hostname
if grep -q "127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1\t$newhost/" /etc/hosts
else
  echo -e "127.0.1.1\t$newhost" >> /etc/hosts
fi

# 4) Initialise this unit's own empty NVMe if the mirror LV is absent.
if ! lvdisplay "$LVM_VG/$MIRROR_LV" >/dev/null 2>&1; then
  log "initialising empty NVMe (LVM)"
  "$GATEWAY_HOME/install/30_setup_nvme_lvm.sh" --wipe
fi
mountpoint -q /srv/vision_mirror || mount /srv/vision_mirror 2>/dev/null || mount -a || true
safe_mkdir "$STATE_DIR"

# 4b) Seed the shadow config from the golden /etc copy (promoted by
#     prepare-golden-image) BEFORE apply-shadow-config runs. Without this, the
#     fresh NVMe has no shadow, so restore_shadow_conf falls back to the packaged
#     example and the clone loses the tuned config (eth1/ingest disabled, wrong
#     SMB/NetBIOS names).
if [[ ! -f "$STATE_DIR/vision-gw.conf" && -f /etc/vision-gw.conf ]]; then
  cp /etc/vision-gw.conf "$STATE_DIR/vision-gw.conf"
  cp /etc/vision-gw.conf "$STATE_DIR/vision-gw.conf.last-good"
  log "seeded shadow config from golden /etc"
fi

# 4c) Grow the root filesystem to fill its partition. Shrunk (PiShrink) images
#     ship a small ext4; PiShrink enlarges the partition but its own resize2fs
#     hook does not survive our overlay/firstboot flow. Do it here explicitly,
#     in the writable window BEFORE the overlay is (re-)enabled below. Idempotent
#     (no-op once the fs already fills the partition), and skipped under overlay.
root_src=$(findmnt -no SOURCE / 2>/dev/null)
if [[ "$root_src" == /dev/* ]]; then
  root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)
  root_partnum=$(printf '%s' "$root_src" | grep -oE '[0-9]+$')
  if [[ -n "$root_disk" && -n "$root_partnum" ]] && command -v parted >/dev/null 2>&1; then
    parted -s "/dev/$root_disk" resizepart "$root_partnum" 100% >/dev/null 2>&1 || true
    # Make the kernel see the enlarged partition BEFORE resize2fs, or resize2fs
    # reads the stale (small) partition size and no-ops. parted's BLKPG alone
    # proved unreliable on the mounted root; partx -u updates it explicitly.
    partx -u "/dev/$root_disk" >/dev/null 2>&1 || partprobe "/dev/$root_disk" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
  fi
  if command -v resize2fs >/dev/null 2>&1; then
    log "growing root filesystem to fill $root_src"
    resize2fs "$root_src" >/dev/null 2>&1 || log "resize2fs failed (non-fatal)"
  fi
fi

# 5) Seed the shared WebUI password (from the eMMC), generate a fresh secret.
if [[ ! -f "$STATE_DIR/webui.passwd" && -f "$SEED_DIR/webui.passwd" ]]; then
  cp "$SEED_DIR/webui.passwd" "$STATE_DIR/webui.passwd"
  chmod 0600 "$STATE_DIR/webui.passwd"
  log "seeded shared WebUI password"
fi
head -c 32 /dev/urandom > "$STATE_DIR/webui.secret"
chmod 0600 "$STATE_DIR/webui.secret"
log "generated fresh WebUI session secret"

# 6) Do NOT apply config or start the stack from here. vision-firstboot.service
#    is ordered Before= vision-gw-config, usb-gadget, vision-sync.timer and smbd,
#    so calling apply-shadow-config (which restarts those) or `systemctl start`
#    on them DEADLOCKS: the (re)start job blocks until firstboot's ordering
#    releases, and firstboot blocks waiting for that job. The normal boot units
#    (vision-gw-config, vision-shadow-config) apply the config, and the enabled
#    services start on their own, once firstboot completes — or after the
#    overlay-enable reboot below.

# 7) Mark done BEFORE any overlay flip, so the flag lands on the real disk.
touch "$DONE_FLAG"
systemctl disable vision-firstboot.service 2>/dev/null || true
log "first-boot personalisation complete: $newhost"

# 8) Optionally re-enable the read-only overlay for the fleet, then reboot.
if [[ -f "$SEED_DIR/enable-overlay" ]]; then
  log "enabling read-only overlay and rebooting"
  "$GATEWAY_HOME/install/20_enable_readonly_overlay.sh" || true
  systemctl reboot
fi

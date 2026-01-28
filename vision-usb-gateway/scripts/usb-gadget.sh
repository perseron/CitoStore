#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_root
load_config

: "${USB_GADGET_NAME:=vision}"
: "${USB_VENDOR_ID:=0x1d6b}"
: "${USB_PRODUCT_ID:=0x0104}"
: "${USB_MANUFACTURER:=VisionGateway}"
: "${USB_PRODUCT:=VisionUSBStorage}"
: "${USB_SERIAL:=CM5-0001}"
: "${USB_CONFIG:=Config 1}"
: "${USB_MAX_POWER:=250}"
: "${LVM_VG:=vg0}"

if [[ ${#USB_LVS[@]} -eq 0 ]]; then
  USB_LVS=(usb_0)
fi

GADGET_DIR=/sys/kernel/config/usb_gadget/$USB_GADGET_NAME
ACTIVE_FILE=/run/vision-usb-active

get_udc() {
  ls /sys/class/udc | head -n1
}

ensure_configfs() {
  mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
}

current_active() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    cat "$ACTIVE_FILE"
  else
    echo "/dev/$LVM_VG/${USB_LVS[0]}"
  fi
}

setup_gadget() {
  ensure_configfs
  mkdir -p "$GADGET_DIR"
  echo "$USB_VENDOR_ID" > "$GADGET_DIR/idVendor"
  echo "$USB_PRODUCT_ID" > "$GADGET_DIR/idProduct"
  mkdir -p "$GADGET_DIR/strings/0x409"
  echo "$USB_SERIAL" > "$GADGET_DIR/strings/0x409/serialnumber"
  echo "$USB_MANUFACTURER" > "$GADGET_DIR/strings/0x409/manufacturer"
  echo "$USB_PRODUCT" > "$GADGET_DIR/strings/0x409/product"

  mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409"
  echo "$USB_CONFIG" > "$GADGET_DIR/configs/c.1/strings/0x409/configuration"
  echo "$USB_MAX_POWER" > "$GADGET_DIR/configs/c.1/MaxPower"

  mkdir -p "$GADGET_DIR/functions/mass_storage.0"
  echo 1 > "$GADGET_DIR/functions/mass_storage.0/stall"
  echo 1 > "$GADGET_DIR/functions/mass_storage.0/removable"
  echo 0 > "$GADGET_DIR/functions/mass_storage.0/ro"
  echo 1 > "$GADGET_DIR/functions/mass_storage.0/nofua"

  ln -sf "$GADGET_DIR/functions/mass_storage.0" "$GADGET_DIR/configs/c.1/"
}

bind_gadget() {
  local dev="$1"
  echo "$dev" > "$GADGET_DIR/functions/mass_storage.0/lun.0/file"
  local udc
  udc=$(get_udc)
  echo "$udc" > "$GADGET_DIR/UDC"
  echo "$dev" > "$ACTIVE_FILE"
}

unbind_gadget() {
  if [[ -f "$GADGET_DIR/UDC" ]]; then
    echo "" > "$GADGET_DIR/UDC" || true
  fi
}

remove_gadget() {
  unbind_gadget
  rm -f "$GADGET_DIR/configs/c.1/mass_storage.0"
  rmdir "$GADGET_DIR/functions/mass_storage.0" 2>/dev/null || true
  rmdir "$GADGET_DIR/configs/c.1/strings/0x409" 2>/dev/null || true
  rmdir "$GADGET_DIR/configs/c.1" 2>/dev/null || true
  rmdir "$GADGET_DIR/strings/0x409" 2>/dev/null || true
  rmdir "$GADGET_DIR" 2>/dev/null || true
}

next_lv() {
  local current="$1"
  local name
  name=$(basename "$current")
  local idx=-1
  for i in "${!USB_LVS[@]}"; do
    if [[ "${USB_LVS[$i]}" == "$name" ]]; then
      idx=$i
      break
    fi
  done
  if [[ $idx -lt 0 ]]; then
    echo "/dev/$LVM_VG/${USB_LVS[0]}"
  else
    local next=$(( (idx + 1) % ${#USB_LVS[@]} ))
    echo "/dev/$LVM_VG/${USB_LVS[$next]}"
  fi
}

case "${1:-}" in
  start)
    setup_gadget
    bind_gadget "$(current_active)"
    ;;
  stop)
    remove_gadget
    ;;
  switch)
    setup_gadget
    local_current=$(current_active)
    new_dev="${2:-$(next_lv "$local_current")}"
    unbind_gadget
    bind_gadget "$new_dev"
    ;;
  status)
    echo "gadget: $GADGET_DIR"
    echo "active: $(current_active)"
    ;;
  *)
    echo "usage: $0 start|stop|switch [dev]|status" >&2
    exit 1
    ;;
esac
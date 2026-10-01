#!/usr/bin/env bash
set -euo pipefail

# The replug-fix update package, end to end through the real apply-update.sh:
# built from its source commit, staged the way the WebUI stages an upload,
# applied (vision-update.service), persisted, re-applied on a simulated overlay
# boot (vision-update-reapply) after the RAM layer lost the file, and refused —
# leaving the unit untouched — on a build it was not made for.
#
# Needs root (apply-update.sh insists), git and python3:
#   docker run --rm -v "$PWD/..:/repo:ro" python:3.11-slim-bookworm bash -c \
#     'apt-get update -qq && apt-get install -y -qq git >/dev/null && \
#      cp -r /repo /r && bash /r/vision-usb-gateway/tests/functional/test_update_package.sh'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
PKG_DIR="$GW/updates/replug-fix"
PREFIX=$(git -C "$GW" rev-parse --show-prefix)

if [[ $(id -u) -ne 0 ]]; then
  echo "must run as root (apply-update.sh requires it)" >&2
  exit 1
fi
git config --global --add safe.directory '*' 2>/dev/null || true

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }
sha() { sha256sum "$1" | cut -c1-16; }

rev=$(sed -n 's/.*"source_commit": *"\([^"]*\)".*/\1/p' "$PKG_DIR/manifest.json")
version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$PKG_DIR/manifest.json")
git -C "$GW" show "$rev:${PREFIX}scripts/mdns-apply-mode.sh" > "$TMP/new.sh"
git -C "$GW" show "bb27fc1:${PREFIX}scripts/mdns-apply-mode.sh" > "$TMP/old.sh"

echo "=== build ==="
# Build from a CRLF copy of the package dir — what a Windows checkout
# (core.autocrlf) hands the builder; the package must still come out LF.
mkdir "$TMP/pkgsrc"
for f in manifest.json install.sh files.txt; do
  sed 's/$/\r/' "$PKG_DIR/$f" > "$TMP/pkgsrc/$f"
done
pkg=$("$GW/scripts/build-update-package.sh" "$TMP/pkgsrc" "$TMP/dist")
check "package built as <version>.tar.gz" "$(basename "$pkg")" "$version.tar.gz"
mkdir "$TMP/unpacked" && tar xzf "$pkg" -C "$TMP/unpacked"
check "carries the fix exactly as in $rev" "$(sha "$TMP/unpacked/files/scripts/mdns-apply-mode.sh")" "$(sha "$TMP/new.sh")"
check "no CRLF in the packaged install.sh / manifest" "$(cat "$TMP/unpacked/install.sh" "$TMP/unpacked/manifest.json" | tr -cd '\r' | wc -c)" 0

# A unit: GATEWAY_HOME with the updater + the OLD script, a mirror, a build stamp.
unit() {  # <build sha>
  rm -rf "$TMP/gw" "$TMP/mirror"
  mkdir -p "$TMP/gw/scripts" "$TMP/mirror/.state"
  # The working tree, CRs stripped (a Windows checkout has them CRLF; the unit
  # gets LF from git).
  for f in apply-update.sh common.sh; do
    tr -d '\r' < "$GW/scripts/$f" > "$TMP/gw/scripts/$f"
  done
  install -m 0755 "$TMP/old.sh" "$TMP/gw/scripts/mdns-apply-mode.sh"
  printf 'CITOSTORE_BUILD_SHA=%s\n' "$1" > "$TMP/citostore-build"
}
# What the WebUI does with an upload (server.py handle_update).
stage_upload() {
  local s="$TMP/mirror/.state/update-staging"
  rm -rf "$s" && mkdir -p "$s" && cp "$pkg" "$s/update.tar.gz" && tar xzf "$s/update.tar.gz" -C "$s"
}
run_update() {  # <apply|reapply>
  local rc=0
  PATH="$TMP/bin:$PATH" MIRROR_MOUNT="$TMP/mirror" GATEWAY_HOME="$TMP/gw" \
    CITOSTORE_BUILD_FILE="$TMP/citostore-build" \
    bash "$TMP/gw/scripts/apply-update.sh" "$1" >"$TMP/out" 2>&1 || rc=$?
  echo "$rc"
}
history() { python3 -c 'import json,sys; print(";".join(h["version"]+"="+h["status"] for h in json.load(open(sys.argv[1]))))' "$TMP/mirror/.state/update-history.json" 2>/dev/null || true; }
installed() { sha "$TMP/gw/scripts/mdns-apply-mode.sh"; }
# apply-update.sh detects the overlay with `findmnt -no FSTYPE /`. Stubbed both
# ways: a container's own root is an overlay too.
root_fstype() {
  mkdir -p "$TMP/bin"
  printf '#!/bin/bash\necho %s\n' "$1" > "$TMP/bin/findmnt"
  chmod +x "$TMP/bin/findmnt"
}
overlay_boot() { root_fstype overlay; }
overlay_off() { root_fstype ext4; }

echo "=== upload on a bb27fc1 unit ==="
unit bb27fc1
stage_upload
check "apply succeeds" "$(run_update apply)" 0
check "script replaced by the fixed one" "$(installed)" "$(sha "$TMP/new.sh")"
check "  ... and executable" "$(stat -c %a "$TMP/gw/scripts/mdns-apply-mode.sh")" 755
check "history shows it ok (WebUI update history)" "$(history)" "$version=ok"
check "persisted for boot-time reapply" "$(test -f "$TMP/mirror/.state/updates/current.tar.gz" && echo yes || echo no)" yes
check "  ... byte-identical to the upload" "$(sha "$TMP/mirror/.state/updates/current.tar.gz")" "$(sha "$pkg")"
check "no temp files left behind" "$(find "$TMP/mirror/.state" -name '*.tmp' | wc -l)" 0

echo "=== next boot (overlay dropped the RAM copy) ==="
install -m 0755 "$TMP/old.sh" "$TMP/gw/scripts/mdns-apply-mode.sh"
overlay_off
check "no overlay: reapply skips" "$(run_update reapply)" 0
check "  ... and leaves the script alone" "$(installed)" "$(sha "$TMP/old.sh")"
overlay_boot
check "reapply succeeds" "$(run_update reapply)" 0
check "fix is back" "$(installed)" "$(sha "$TMP/new.sh")"
check "history shows both runs" "$(history)" "$version=ok;$version=ok"
overlay_off

echo "=== persisted archive corrupted (power cut while it was stored) ==="
cp "$TMP/mirror/.state/updates/current.tar.gz" "$TMP/good.tar.gz"
head -c $(( $(stat -c %s "$TMP/good.tar.gz") / 2 )) "$TMP/good.tar.gz" >"$TMP/mirror/.state/updates/current.tar.gz"
install -m 0755 "$TMP/old.sh" "$TMP/gw/scripts/mdns-apply-mode.sh"
overlay_boot
check "reapply does not fail the boot" "$(run_update reapply)" 0
check "corrupt archive deleted" "$(test -f "$TMP/mirror/.state/updates/current.tar.gz" && echo yes || echo no)" no
check "history says why" "$(history | awk -F';' '{print $NF}')" "unknown=removed: corrupt archive"
check "next boot clean" "$(run_update reapply)" 0
overlay_off
cp "$TMP/good.tar.gz" "$TMP/mirror/.state/updates/current.tar.gz"
# A truncated history (what the old non-atomic write left after a power cut).
printf '[{"version": "x", "status": "ok", "ts": "t"}, {"vers' > "$TMP/mirror/.state/update-history.json"

echo "=== unit reflashed to a newer image, package still persisted on the NVMe ==="
# Seen live: every boot the reapply failed ("nothing changed") and the unit
# came up degraded. The image carries its own code, so the package is deleted.
printf 'CITOSTORE_BUILD_SHA=f9b2b6a\n' > "$TMP/citostore-build"
install -m 0755 "$TMP/old.sh" "$TMP/gw/scripts/mdns-apply-mode.sh"   # stands in for the image's copy
overlay_boot
check "reapply succeeds instead of failing the boot" "$(run_update reapply)" 0
check "package not run over the image's code" "$(installed)" "$(sha "$TMP/old.sh")"
check "history says removed" "$(history | awk -F';' '{print $NF}')" "$version=removed"
check "package deleted from the NVMe" "$(find "$TMP/mirror/.state/updates" -type f | wc -l)" 0
check "next boot: nothing to reapply, still fine" "$(run_update reapply)" 0
# (the truncated history restarted the list: only the "removed" entry)
check "  ... and no new history entry" "$(history | tr ';' '\n' | grep -c .)" 1
overlay_off

echo "=== upload on a build it was not made for ==="
unit 4bd1db0
stage_upload
check "apply refuses" "$(run_update apply)" 1
check "unit left untouched" "$(installed)" "$(sha "$TMP/old.sh")"
check "history shows it failed" "$(history)" "$version=failed"
check "nothing persisted for reapply" "$(test -f "$TMP/mirror/.state/updates/current.tar.gz" && echo yes || echo no)" no
check "the reason is readable" "$(grep -c "this unit is '4bd1db0'" "$TMP/out")" 1

echo "=== builder refuses a manifest without compatible_builds ==="
mkdir "$TMP/nocompat"
cp "$TMP/pkgsrc/install.sh" "$TMP/pkgsrc/files.txt" "$TMP/nocompat/"
grep -v compatible_builds "$TMP/pkgsrc/manifest.json" > "$TMP/nocompat/manifest.json"
rc=0; "$GW/scripts/build-update-package.sh" "$TMP/nocompat" "$TMP/dist2" >"$TMP/out" 2>&1 || rc=$?
check "build fails" "$rc" 1
check "  ... saying why" "$(grep -c compatible_builds "$TMP/out")" 1
check "  ... and writes no package" "$(find "$TMP/dist2" -type f 2>/dev/null | wc -l)" 0

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"

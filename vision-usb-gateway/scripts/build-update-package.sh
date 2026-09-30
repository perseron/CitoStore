#!/usr/bin/env bash
set -euo pipefail

# Build a WebUI update package (Maintenance -> System Update) from a package
# directory under updates/: manifest.json + install.sh + the repo files listed in
# files.txt (paths relative to vision-usb-gateway/), taken from the manifest's
# source_commit so the package is reproducible whatever is checked out.
#
#   scripts/build-update-package.sh updates/replug-fix [out_dir]
#
# Output: <out_dir>/<version>.tar.gz (default out_dir: dist/).

pkg_dir=${1:?usage: build-update-package.sh <updates/pkg-dir> [out_dir]}
GW=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out_dir=${2:-$GW/dist}
pkg_dir=$(cd "$pkg_dir" && pwd)

for f in manifest.json install.sh files.txt; do
  [[ -f "$pkg_dir/$f" ]] || { echo "missing $pkg_dir/$f" >&2; exit 1; }
done

field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$pkg_dir/manifest.json" | head -1; }
version=$(field version)
rev=$(field source_commit)
[[ -n "$version" && -n "$rev" ]] || { echo "manifest.json needs version and source_commit" >&2; exit 1; }

prefix=$(git -C "$GW" rev-parse --show-prefix)   # e.g. vision-usb-gateway/
git -C "$GW" rev-parse --verify --quiet "$rev^{commit}" >/dev/null \
  || { echo "source_commit $rev not found in this repo" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Strip CRs: on a Windows checkout (core.autocrlf) these come out CRLF, and an
# install.sh whose first line ends in a CR dies on the unit before doing anything.
for f in manifest.json install.sh files.txt; do
  tr -d '\r' < "$pkg_dir/$f" > "$tmp/$f"
done
chmod 0755 "$tmp/install.sh"
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  mkdir -p "$tmp/files/$(dirname "$rel")"
  git -C "$GW" show "$rev:$prefix$rel" > "$tmp/files/$rel"
  if [[ "$rel" == *.sh ]]; then
    bash -n "$tmp/files/$rel" || { echo "$rel@$rev fails bash -n" >&2; exit 1; }
  fi
done < "$tmp/files.txt"
bash -n "$tmp/install.sh"

mkdir -p "$out_dir"
out="$out_dir/$version.tar.gz"
tar czf "$out" -C "$tmp" .
echo "$out"

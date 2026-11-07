#!/usr/bin/env bash
# Download the pinned libghostty-vt tarballs (pin.toml) into DIR (default: tarballs/ beside this script, or
# $GHOSTTY_VT_TARBALLS), checking the sha256 of each, and its minisign signature when minisign is installed.
# build.rs never downloads: run this first, or ship the files in the offline bundle.  Usage: fetch.sh [DIR]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:-${GHOSTTY_VT_TARBALLS:-$here/tarballs}}
KEY=RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$here/pin.toml")
mkdir -p "$dir"
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
for section in source deps; do
  file=$(awk -v s="[$section]" '$0 == s {on=1; next} /^\[/ {on=0} on && $1 == "file" {gsub(/"/, "", $3); print $3}' "$here/pin.toml")
  sha=$(awk -v s="[$section]" '$0 == s {on=1; next} /^\[/ {on=0} on && $1 == "sha256" {gsub(/"/, "", $3); print $3}' "$here/pin.toml")
  if [ -f "$dir/$file" ] && [ "$(sha256_of "$dir/$file")" = "$sha" ]; then continue; fi
  curl -fsSL -o "$dir/$file.new" "https://release.files.ghostty.org/libghostty-vt/$version/$file"
  got=$(sha256_of "$dir/$file.new")
  [ "$got" = "$sha" ] || { rm -f "$dir/$file.new"; echo "fetch.sh: $file is not the pinned file (sha256 $got, expected $sha)" >&2; exit 1; }
  if command -v minisign >/dev/null 2>&1; then
    curl -fsSL -o "$dir/$file.minisig" "https://release.files.ghostty.org/libghostty-vt/$version/$file.minisig"
    minisign -Vm "$dir/$file.new" -x "$dir/$file.minisig" -P "$KEY" >/dev/null || { rm -f "$dir/$file.new"; echo "fetch.sh: the signature of $file does not verify" >&2; exit 1; }
  fi
  mv "$dir/$file.new" "$dir/$file"
done
echo "fetch.sh: libghostty-vt $version in $dir"

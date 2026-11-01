#!/usr/bin/env bash
# Before a cargo cache is saved: drop what the next run rebuilds anyway, so the cache holds the dependencies only.
# A fresh checkout's sources are newer than any cached output, so cargo rebuilds the local packages (the workspace's
# and its path dependencies) whatever the cache holds: their artifacts, cargo's incremental data and the registry's
# unpacked sources (unpacked again from the kept .crate files) only take space. docs/develop/ci.md, "Caches"
#
#   cargo-prune.sh MANIFEST TARGET_DIR [--keep-bins]
#
# --keep-bins: leave the local packages' top-level binaries (a later step of the job runs or uploads them).
# Needs jq; bash 3.2-safe. Deleting too much only costs a rebuild, never a wrong result.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: cargo-prune.sh MANIFEST TARGET_DIR [--keep-bins]" >&2; exit 2; }
manifest=$1 target=$2 keep=${3:-}
[ -d "$target" ] || { echo "cargo-prune.sh: no $target" >&2; exit 0; }

# the local packages' names (dashes, as in .fingerprint/ and build/) and their targets' crate names (underscores)
meta=$(cargo metadata --format-version 1 --offline --manifest-path "$manifest")
pkgs=$(jq -r '.packages[] | select(.source == null) | .name' <<<"$meta" | sort -u)
crates=$(jq -r '.packages[] | select(.source == null) | .targets[].name | gsub("-"; "_")' <<<"$meta" | sort -u)
bins=$(jq -r '.packages[] | select(.source == null) | .targets[] | select(any(.kind[]; . == "bin" or . == "example")) | .name' <<<"$meta" | sort -u)

before=$(du -sk "$target" | cut -f1)
# every profile directory, of the host and of each --target triple: the ones with a .fingerprint
find "$target" -type d -name .fingerprint -prune | while IFS= read -r fp; do
  dir=$(dirname "$fp")
  rm -rf "$dir/incremental"
  for p in $pkgs; do rm -rf "$dir/.fingerprint/$p-"* "$dir/build/$p-"*; done
  for c in $crates; do rm -rf "$dir/deps/$c-"* "$dir/deps/lib$c-"* "$dir/deps/lib$c."* "$dir/examples/$c-"*; done
  if [ "$keep" != --keep-bins ]; then
    for b in $bins; do rm -f "$dir/$b" "$dir/$b.d" "$dir/examples/$b" "$dir/examples/$b.d"; done
  fi
done
rm -rf "${CARGO_HOME:-$HOME/.cargo}/registry/src"
echo "cargo-prune.sh: $target ${before} KiB -> $(du -sk "$target" | cut -f1) KiB"

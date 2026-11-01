#!/usr/bin/env bash
# Before a cargo cache is saved: drop what the next run rebuilds anyway, so the cache holds the dependencies only.
# A fresh checkout's sources are newer than any cached output, so cargo rebuilds the local packages (the workspace's
# and its path dependencies) whatever the cache holds: their artifacts, cargo's incremental data and the registry's
# unpacked sources (unpacked again from the kept .crate files) only take space. docs/develop/ci.md, "Caches"
#
#   cargo-prune.sh MANIFEST TARGET_DIR [--keep-bins]
#
# --keep-bins: leave the local packages' top-level binaries (a later step of the job runs or uploads them).
# It never fails a job: whatever it cannot work out, it warns and leaves as it is (an unpruned cache is only bigger).
# The local packages come from `cargo metadata --no-deps` (the workspace, offline, nothing to download) and Cargo.lock
# (the packages without a source: path dependencies outside the workspace). Deleting too much only costs a rebuild,
# never a wrong result. Needs jq; bash 3.2-safe.
set -uo pipefail
[ $# -ge 2 ] || { echo "usage: cargo-prune.sh MANIFEST TARGET_DIR [--keep-bins]" >&2; exit 2; }
manifest=$1 target=$2 keep=${3:-}
skip() { echo "::warning::cargo-prune.sh: $*; nothing pruned"; exit 0; }
[ -d "$target" ] || skip "no $target"
command -v jq >/dev/null || skip "no jq"
meta=$(cargo metadata --format-version 1 --no-deps --offline --manifest-path "$manifest") || skip "cargo metadata failed"

# the local packages' names (dashes, as in .fingerprint/ and build/), their targets' crate names (underscores) and
# their binaries and examples
lock="$(jq -r .workspace_root <<<"$meta")/Cargo.lock"
paths=""
if [ -f "$lock" ]; then
  paths=$(awk '/^\[\[package\]\]/ { if (n != "" && !s) print n; n = ""; s = 0; next }
               /^name = / { n = $3; gsub(/"/, "", n) }
               /^source = / { s = 1 }
               END { if (n != "" && !s) print n }' "$lock") || skip "cannot read $lock"
fi
members=$(jq -r '.packages[].name' <<<"$meta") || skip "no packages in the metadata"
pkgs=$(printf '%s\n%s\n' "$members" "$paths" | sort -u)
crates=$( { jq -r '.packages[].targets[].name' <<<"$meta"; printf '%s\n' "$paths"; } | tr - _ | sort -u)
bins=$(jq -r '.packages[].targets[] | select(any(.kind[]; . == "bin" or . == "example")) | .name' <<<"$meta" | sort -u)
[ -n "$pkgs" ] || skip "no local packages"

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
exit 0

#!/usr/bin/env bash
# Before a cargo cache is saved: drop what the next run does not reuse.  The local packages' artifacts (the workspace's
# and its path dependencies') stay: .github/ci/commit-times.sh gives the next checkout's unchanged files their last
# commit's time, so cargo reuses them and rebuilds only what changed.  Cargo's incremental data (CI builds with
# CARGO_INCREMENTAL=0), the registry's unpacked sources (unpacked again from the kept .crate files) and the top-level
# copies of the binaries (cargo copies them out of deps/ again) only take space. docs/develop/ci.md, "What is cached"
#
#   cargo-prune.sh MANIFEST TARGET_DIR [--keep-bins]
#
# --keep-bins: leave the local packages' top-level binaries (a later step of the job runs or uploads them).
# It never fails a job: whatever it cannot work out, it warns and leaves as it is (an unpruned cache is only bigger).
# The binaries come from `cargo metadata --no-deps` (the workspace, offline, nothing to download). Deleting too much
# only costs a rebuild, never a wrong result. Needs jq; bash 3.2-safe.
set -uo pipefail
[ $# -ge 2 ] || { echo "usage: cargo-prune.sh MANIFEST TARGET_DIR [--keep-bins]" >&2; exit 2; }
manifest=$1 target=$2 keep=${3:-}
skip() { echo "::warning::cargo-prune.sh: $*; nothing pruned"; exit 0; }
[ -d "$target" ] || skip "no $target"
command -v jq >/dev/null || skip "no jq"
meta=$(cargo metadata --format-version 1 --no-deps --offline --manifest-path "$manifest") || skip "cargo metadata failed"

# the workspace's binaries and examples
bins=$(jq -r '.packages[].targets[] | select(any(.kind[]; . == "bin" or . == "example")) | .name' <<<"$meta" | sort -u) ||
  skip "no packages in the metadata"

before=$(du -sk "$target" | cut -f1)
# every profile directory, of the host and of each --target triple: the ones with a .fingerprint
find "$target" -type d -name .fingerprint -prune | while IFS= read -r fp; do
  dir=$(dirname "$fp")
  rm -rf "$dir/incremental"
  if [ "$keep" != --keep-bins ]; then
    for b in $bins; do rm -f "$dir/$b" "$dir/$b.d" "$dir/examples/$b" "$dir/examples/$b.d"; done
  fi
done
rm -rf "${CARGO_HOME:-$HOME/.cargo}/registry/src"
echo "cargo-prune.sh: $target ${before} KiB -> $(du -sk "$target" | cut -f1) KiB"
exit 0

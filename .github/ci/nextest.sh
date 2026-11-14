#!/usr/bin/env bash
# nextest.sh: cargo-nextest 0.9.151, the workspace's test runner (each test in a process of its own, so a crash or leftover
# state never reaches another, and the run is shorter: 46 s against cargo test's 59-92 s for the hub's suite). The
# release tarball for this OS, checked against its SHA-256 (the release's published digest), into DIR (default
# $RUNNER_TEMP), which goes on GITHUB_PATH. Usage: nextest.sh [DIR]. docs/develop/ci.md
set -euo pipefail
ver=0.9.151
case "$(uname -s)" in
  Linux) asset=x86_64-unknown-linux-musl sha256=6b284d6fde9670dfb6ee10ea9d9abbc85f95643d3f592472d420d82e257b3a6c ;;
  Darwin) asset=universal-apple-darwin sha256=d1d7d025d4bfc9fb154cd76aea3949bd78534829a0589abefa6e5dd4edb135dd ;;
  *) echo "nextest.sh: no cargo-nextest for $(uname -s)" >&2; exit 1 ;;
esac
dir=${1:-$RUNNER_TEMP}
mkdir -p "$dir"
curl -fsSL -o "$dir/cargo-nextest.tgz" \
  "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-$ver/cargo-nextest-$ver-$asset.tar.gz"
sum=(sha256sum); command -v sha256sum >/dev/null || sum=(shasum -a 256)   # macOS has only shasum
echo "$sha256  $dir/cargo-nextest.tgz" | "${sum[@]}" -c -
tar -xzf "$dir/cargo-nextest.tgz" -C "$dir" cargo-nextest
rm "$dir/cargo-nextest.tgz"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$dir" >> "$GITHUB_PATH"; fi
"$dir/cargo-nextest" nextest --version

#!/usr/bin/env bash
# The runner bundle (sleipnir, drgnx-key, drgnx-px): static musl binaries, into target/bundle/<arch>/
# (docs/develop/sleipnir.md). Run from the repository root:  bash xtask/runner-bundle.sh [--arch x86_64|aarch64]
# Needs the Rust target <arch>-unknown-linux-musl (rustup target add …); another architecture links with rust-lld.
set -euo pipefail
manifest=Cargo.toml
target=target
arch=$(uname -m)
while (($#)); do
  case $1 in
    --arch) arch=${2:?--arch needs x86_64 or aarch64}; shift ;;
    *) echo "runner-bundle: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
case $arch in x86_64 | aarch64) ;; arm64) arch=aarch64 ;; *) echo "runner-bundle: no bundle for $arch" >&2; exit 2 ;; esac
triple=$arch-unknown-linux-musl
if [ "$arch" != "$(uname -m)" ]; then
  if [ "$arch" = aarch64 ]; then l=AARCH64; else l=X86_64; fi
  export "CARGO_TARGET_${l}_UNKNOWN_LINUX_MUSL_LINKER=rust-lld"
fi
CARGO_TARGET_DIR=$target/bundle-build cargo build --release --locked --target "$triple" --manifest-path "$manifest" \
  -p sleipnir -p ferja --bins
dir=$target/bundle/$arch
mkdir -p "$dir"
for b in sleipnir drgnx-key drgnx-px; do
  n=$b; [ "$b" != drgnx-px ] || n=drgnx-px-$arch-linux-musl   # the name the hub looks for (image::binary_for)
  cp "$target/bundle-build/$triple/release/$b" "$dir/$n.new" && chmod 755 "$dir/$n.new" && mv -f "$dir/$n.new" "$dir/$n"
  case $(file -b -L "$dir/$n") in
    *"statically linked"* | *"static-pie linked"*) ;;
    *) echo "runner-bundle: $dir/$n is not a static binary" >&2; exit 1 ;;
  esac
done
echo "runner-bundle: $arch in $dir"

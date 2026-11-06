#!/usr/bin/env bash
# wasm-target.sh: the wasm32-wasip2 target for the plugin fixtures, then the fixtures built for it. The plugin tests
# load real WASM components (runtime/plugins/fixtures) that brokkr's test support builds at test time; building them
# here first names a missing target or a broken fixture in its own step instead of in the first plugin test.
# With rustup (the macOS runner, the Ubuntu jobs): `rustup target add`. Without it (the Fedora container's packaged
# Rust, which has wasm32-wasip1 but no wasip2 standard library, and cannot use an upstream one: the crates it builds
# are tagged with its own rustc): rustup-init (checked against its published SHA-256) installs the same rustc version
# with the target for the fixtures alone, and DRGNX_WASM_CARGO (GITHUB_ENV) tells the test support to build them with
# it. Run from the repository root.
set -euo pipefail
cargo=cargo
if command -v rustup >/dev/null 2>&1; then
  rustup target add wasm32-wasip2
else
  ver=$(rustc -V | cut -d' ' -f2)
  host=$(uname -m)-unknown-linux-gnu
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  base="https://static.rust-lang.org/rustup/dist/$host/rustup-init"
  curl -fsSL "$base" -o "$work/rustup-init"
  want=$(curl -fsSL "$base.sha256" | cut -d' ' -f1)
  echo "$want  $work/rustup-init" | sha256sum -c -
  chmod +x "$work/rustup-init"
  "$work/rustup-init" -y --no-modify-path --profile minimal --default-toolchain "$ver" --target wasm32-wasip2
  cargo="$HOME/.cargo/bin/cargo"
  if [ -n "${GITHUB_ENV:-}" ]; then echo "DRGNX_WASM_CARGO=$cargo" >> "$GITHUB_ENV"; fi
fi
"$cargo" build --locked --release --target wasm32-wasip2 --manifest-path runtime/plugins/fixtures/Cargo.toml

#!/usr/bin/env bash
# wasm-target.sh: the plugin fixtures and the template, built for wasm32-wasip2.
# The plugin tests load real WASM components (crates/hub/plugins/fixtures) that brokkr's test support builds at test time;
# building them here, into the folders the test support builds into (target/plugin-fixtures), names a broken fixture in
# its own step, and leaves the tests' own build nothing to do (a minute of brokkr's lib tests on a cold macOS runner).
# The target is one of mise.toml's Rust targets (installed with the toolchain, in the image or the tool bundle); the
# `target add` is a no-op there and a safety net for a toolchain that came from elsewhere. Run from the repository root.
set -euo pipefail
rustup target add wasm32-wasip2
cargo build --locked --release --target wasm32-wasip2 --manifest-path crates/hub/plugins/fixtures/Cargo.toml \
  --target-dir target/plugin-fixtures/build
cargo build --locked --release --target wasm32-wasip2 --manifest-path crates/hub/plugins/template/Cargo.toml \
  --target-dir target/plugin-fixtures/template/build

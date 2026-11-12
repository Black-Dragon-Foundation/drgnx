#!/usr/bin/env bash
# rust.sh [OPTION...]: the Rust every CI job builds with, never the runner's moving `stable` (1.100's new build-dir
# layout moved test binaries out of target/<profile>/deps and broke every lookup of a sibling binary, 2026-11-12).
# The version is test/container/rust-version, the one place it is named (the Fedora image's packages take it too:
# rust-packages.sh); a move to a newer Rust is an edit of that file. Installs it with rustup (OPTIONs pass to
# `rustup toolchain install`: --component, --target), makes it the default, and names it in RUSTUP_TOOLCHAIN for the
# job's later steps. Run from the repository root. docs/develop/ci.md, "The Rust toolchain"
set -euo pipefail
ver=$(tr -d '[:space:]' < "$(dirname "$0")/../../test/container/rust-version")
rustup toolchain install "$ver" --profile minimal --no-self-update "$@"
rustup default "$ver"
if [ -n "${GITHUB_ENV:-}" ]; then echo "RUSTUP_TOOLCHAIN=$ver" >> "$GITHUB_ENV"; fi
rustc -V

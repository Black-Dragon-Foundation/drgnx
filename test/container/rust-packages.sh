#!/bin/sh
# The packages of the Rust runtime's Fedora 45 job (runtime.yml's `linux`: fmt, clippy, tests, conformance, perf) and of
# the timing lane's Rust step (test/timing-rust.sh): the toolchain, git for the checkout and commit-times.sh, and the
# tools the tests run.  setpriv is in util-linux (the fedora image has only util-linux-core; the `sudo` rows and
# draugr's pdeathsig test run it); diffutils for the rows that compare with cmp; curl, tar and xz for nidhogg.sh (curl
# for .github/ci/models.sh too); the Vulkan loader and Mesa's drivers for llvmpipe, the software adapter Hrafn's GPU
# tests run the real shaders on; vttest for the terminal worker's vttest goldens (drgnx-term tests/vttest.rs).
# Containerfile.rust runs it into the prebuilt image; a job without that image (a change to its inputs not yet on
# main) runs it itself.  docs/develop/ci.md, "Prebuilt images"
# Rust is the version in rust-version beside this script (the one place CI names it: .github/ci/rust.sh), never
# Fedora's newest: a Fedora that no longer has it fails here, and moving on is an edit of that file.
set -eu
rust=$(tr -d '[:space:]' < "$(dirname "$0")/rust-version")
dnf -y install git "cargo-$rust" "rust-$rust" gcc "clippy-$rust" "rustfmt-$rust" tar zstd gzip procps-ng util-linux \
  bubblewrap jq diffutils curl xz vulkan-loader mesa-vulkan-drivers vttest
dnf clean all
rustc -V | grep -q "^rustc $rust " || { echo "rust-packages.sh: rustc is $(rustc -V), not $rust" >&2; exit 1; }

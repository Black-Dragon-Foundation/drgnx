#!/bin/sh
# The packages of the Rust runtime's Fedora 45 job (runtime.yml's `linux`: fmt, clippy, tests, conformance, perf) and of
# the timing lane's Rust step (test/timing-rust.sh): the toolchain, git for the checkout and commit-times.sh, and the
# tools the tests run.  setpriv is in util-linux (the fedora image has only util-linux-core; the `sudo` rows and
# draugr's pdeathsig test run it); diffutils for the rows that compare with cmp; curl, tar and xz for nidhogg.sh (curl
# for .github/ci/models.sh too); the Vulkan loader and Mesa's drivers for llvmpipe, the software adapter Hrafn's GPU
# tests run the real shaders on; vttest for the terminal worker's vttest goldens (drgnx-term tests/vttest.rs).
# Containerfile.rust runs it into the prebuilt image; a job without that image (a change to its inputs not yet on
# main) runs it itself.  docs/develop/ci.md, "Prebuilt images"
set -eu
dnf -y install git cargo rust gcc clippy rustfmt tar zstd gzip procps-ng util-linux bubblewrap jq diffutils curl xz \
  vulkan-loader mesa-vulkan-drivers vttest
dnf clean all

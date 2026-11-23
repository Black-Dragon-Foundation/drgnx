#!/bin/sh
# The system packages of the Rust runtime's Fedora 45 job (runtime.yml's `linux`: fmt, clippy, tests, conformance, perf)
# and of the timing lane's Rust step (test/timing-rust.sh): git for the checkout and commit-times.sh, a C compiler for
# the build scripts, and the tools the tests run. The Rust toolchain and the cargo tools are not here: they are mise's
# (.github/ci/mise.toml, installed by mise.sh, in Containerfile.rust). setpriv is in util-linux (the fedora image has
# only util-linux-core; the `sudo` rows and draugr's pdeathsig test run it); diffutils for the rows that compare with
# cmp; curl, tar and xz for mise.sh and nidhogg.sh (curl for .github/ci/models.sh too); the Vulkan loader and Mesa's
# drivers for llvmpipe, the software adapter Hrafn's GPU tests run the real shaders on; vttest for the terminal
# worker's vttest goldens (glugg tests/vttest.rs); the Wayland client, xkbcommon and pixman headers that skel and
# ritari link (crates/ui; pixman: Smithay's pixman renderer).
# Containerfile.rust runs it into the prebuilt image; a job without that image (a change to its inputs not yet on
# main) runs it itself, then .github/ci/mise.sh.  docs/develop/ci.md, "Prebuilt images"
set -eu
dnf -y install git gcc tar zstd gzip procps-ng util-linux \
  bubblewrap jq diffutils curl xz vulkan-loader mesa-vulkan-drivers vttest wayland-devel libxkbcommon-devel pixman-devel pkgconf-pkg-config
dnf clean all

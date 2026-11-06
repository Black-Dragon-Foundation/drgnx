#!/bin/sh
# bubblewrap 0.12.0 (gleipnir's floor; Ubuntu's apt has 0.9.0), its tarball checked against the pinned sha256, built
# from source into OUT/bwrap.  The escape suite's runner jobs install it as /usr/bin/bwrap (Gleipnir trusts a bwrap
# only where root alone can change it, and the runner image makes /usr/local group-writable).  The prebuilt image
# (Containerfile beside this, one per architecture) runs it on ubuntu:24.04; a job without that image runs it on the
# runner.  Usage: build.sh OUT   (as root, or with passwordless sudo).  docs/develop/ci.md, "Prebuilt images"
set -eu
out=$1
root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
root apt-get update
root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils gcc libc6-dev meson ninja-build pkg-config libcap-dev
work=$(mktemp -d)
curl -fsSL --retry 3 -o "$work/bwrap.tar.xz" https://github.com/containers/bubblewrap/releases/download/v0.12.0/bubblewrap-0.12.0.tar.xz
echo "9760d007363e3abba7c747489910f9f82d9fca53ba3bd3282e396fa3c97a3314  $work/bwrap.tar.xz" | sha256sum -c -
tar -xJf "$work/bwrap.tar.xz" -C "$work"
cd "$work/bubblewrap-0.12.0"
meson setup _build --prefix=/usr -Dman=disabled -Dbash_completion=disabled -Dzsh_completion=disabled -Dselinux=disabled -Dtests=false
ninja -C _build
mkdir -p "$out"
cp _build/bwrap "$out/bwrap"
chmod 0755 "$out/bwrap"
rm -r "$work"

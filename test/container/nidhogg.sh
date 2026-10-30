#!/usr/bin/env bash
# Install Nidhogg's release tarball for drgnx's CI: the test images (Containerfile*) and the macOS job use it, so the
# suite runs on the Emacs drgnx ships on.  Usage: nidhogg.sh DISTRO [TARBALL]   (fedora-44 | fedora-45 | ubuntu-26.04 | macos)
#
# TARBALL: install that Nidhogg tarball instead of the pinned release (Nidhogg's CI runs drgnx's tiers on the tarball it
# just built, .github/workflows/drgnx-tiers.yml): no download and no pinned checksum (the run built it), the version is
# the tarball's top directory (nidhogg-VERSION).
#
# This file is the single place the pin lives (install.sh pins the same version, checked by
# test/unit/ci-nidhogg-test.el): bump NIDHOGG_VERSION and the sha256 lines together, from the release's SHA256SUMS.
# The Containerfiles name the version too (their ENV DRGNX_EMACS), so a bump changes their hash and with it the image tag.
#
# Linux: unpacks to /opt/nidhogg/VERSION (the prefix the tarball was built for), installs its share/nidhogg/deps.runtime
# with dnf or apt-get, links /usr/local/bin/{nidhogg,nidhoggclient,emacs,emacsclient} to it.
# macOS: unpacks to $RUNNER_TEMP/nidhogg, installs its deps.runtime with Homebrew and appends DRGNX_EMACS=… to $GITHUB_ENV.
# bash 3.2-safe (macOS).
set -eu

NIDHOGG_VERSION=31.1-nidhogg.4
NIDHOGG_URL=https://github.com/Black-Dragon-Foundation/nidhogg/releases/download

distro=${1:-}
case "$distro" in
  fedora-44)    asset=fedora-44-x86_64;    sha=2efba5d6390464a58ea58b6de90727dc01e6adb36ca8228a148910cc71edd4f5 ;;
  fedora-45)    asset=fedora-45-x86_64;    sha=1ba5572e1f30701c30cd728cab667a7297dd7af7fe7cc16c84eeac30897e1697 ;;
  ubuntu-26.04) asset=ubuntu-26.04-x86_64; sha=ff23b8786643eefa24ffcfa488657f3c3bec38acc659c02f2ab4b0408f2b1841 ;;
  macos)        asset=macos-arm64;         sha=31b51429e662603eec3f5faf5ce9086dca7fa4aa0b00eee18fb769c7eb908f1c ;;
  *) echo "usage: nidhogg.sh fedora-44|fedora-45|ubuntu-26.04|macos" >&2; exit 2 ;;
esac

local_tarball=${2:-}
if [ -n "$local_tarball" ] && [ ! -f "$local_tarball" ]; then echo "nidhogg.sh: $local_tarball does not exist" >&2; exit 2; fi
tarball="nidhogg-$NIDHOGG_VERSION-$asset.tar.xz"
work=$(mktemp -d "${TMPDIR:-/tmp}/nidhogg.XXXXXX")
trap 'rm -r "$work"' EXIT

fetch() { # download and verify the tarball into $work (TARBALL given: copy it, and take its version)
  if [ -n "$local_tarball" ]; then
    cp "$local_tarball" "$work/$tarball"
    NIDHOGG_VERSION=$(tar -tJf "$work/$tarball" | head -n 1 | cut -d/ -f1)
    NIDHOGG_VERSION=${NIDHOGG_VERSION#nidhogg-}
    return
  fi
  curl -fsSL --retry 3 -o "$work/$tarball" "$NIDHOGG_URL/v$NIDHOGG_VERSION/$tarball"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$sha  $work/$tarball" | sha256sum -c -
  else
    echo "$sha  $work/$tarball" | shasum -a 256 -c -
  fi
}

unpack() { # DIR — the tarball's one top directory becomes DIR
  mkdir -p "$1"
  tar -xJf "$work/$tarball" -C "$1" --strip-components=1
}

deps() { # FILE — the package names in a deps.runtime (comments and blank lines left out)
  grep -v '^[[:space:]]*\(#\|$\)' "$1"
}

if [ "$distro" = macos ]; then
  dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nidhogg"
  command -v xz >/dev/null 2>&1 || brew install xz
  fetch
  unpack "$dir"
  # shellcheck disable=SC2046
  brew install $(deps "$dir/deps.runtime")
  emacs="$dir/Nidhogg.app/Contents/MacOS/Emacs"
  test -x "$emacs"
  if [ -n "${GITHUB_ENV:-}" ]; then echo "DRGNX_EMACS=$emacs" >> "$GITHUB_ENV"; fi
  "$emacs" --version | head -1
  exit 0
fi

# Linux: the tools the download needs, then the tarball and what it needs at run time
if command -v dnf >/dev/null 2>&1; then
  dnf -y install curl tar xz
else
  apt-get update && apt-get -y install --no-install-recommends curl ca-certificates tar xz-utils
fi
fetch
prefix=/opt/nidhogg/$NIDHOGG_VERSION
unpack "$prefix"
if command -v dnf >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  dnf -y install $(deps "$prefix/share/nidhogg/deps.runtime") && dnf clean all
else
  # shellcheck disable=SC2046
  apt-get -y install --no-install-recommends $(deps "$prefix/share/nidhogg/deps.runtime") && rm -r /var/lib/apt/lists/*
fi
mkdir -p /usr/local/bin
ln -sf "$prefix/bin/nidhogg" /usr/local/bin/nidhogg
ln -sf "$prefix/bin/nidhoggclient" /usr/local/bin/nidhoggclient
ln -sf "$prefix/bin/nidhogg" /usr/local/bin/emacs
ln -sf "$prefix/bin/nidhoggclient" /usr/local/bin/emacsclient
/usr/local/bin/nidhogg --version | head -1

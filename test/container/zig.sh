#!/usr/bin/env bash
# Install the pinned Zig for CI: the Rust job's image (Containerfile.rust) and the macOS job use it to build the
# terminal engine (runtime/crates/ghostty-vt-sys builds libghostty-vt from pinned sources; Zig is a build tool only).
# Usage: zig.sh [linux|macos]   (default: this machine's)
#
# The tarball's sha256 and Zig's minisign signature (the public key ziglang.org publishes) are both checked before
# anything is unpacked.  install.sh pins the same version and checksums (checked by test/unit/install-test.el): bump
# ZIG_VERSION and the sha256 lines together, from https://ziglang.org/download/index.json.
#
# Linux: unpacks to /opt/zig/VERSION and links /usr/local/bin/zig.  macOS: unpacks to $RUNNER_TEMP/zig and appends it
# to $GITHUB_PATH.  bash 3.2-safe (macOS).
set -eu

ZIG_VERSION=0.17.0
ZIG_URL=https://ziglang.org/download
ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U

os=${1:-}
if [ -z "$os" ]; then case "$(uname -s)" in Darwin) os=macos ;; *) os=linux ;; esac; fi
arch=$(uname -m); [ "$arch" != arm64 ] || arch=aarch64
case "$arch-$os" in
  x86_64-linux)  sha=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
  aarch64-linux) sha=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
  x86_64-macos)  sha=4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6 ;;
  aarch64-macos) sha=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a ;;
  *) echo "usage: zig.sh [linux|macos] (x86_64 or aarch64)" >&2; exit 2 ;;
esac

name="zig-$arch-$os-$ZIG_VERSION"
work=$(mktemp -d "${TMPDIR:-/tmp}/zig.XXXXXX")
trap 'rm -r "$work"' EXIT

if ! command -v minisign >/dev/null 2>&1; then
  case "$os" in
    linux) dnf -y install minisign ;;
    macos) brew install minisign ;;
  esac
fi
curl -fsSL -o "$work/$name.tar.xz" "$ZIG_URL/$ZIG_VERSION/$name.tar.xz"
curl -fsSL -o "$work/$name.tar.xz.minisig" "$ZIG_URL/$ZIG_VERSION/$name.tar.xz.minisig"
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$work/$name.tar.xz" | cut -d' ' -f1); else got=$(shasum -a 256 "$work/$name.tar.xz" | cut -d' ' -f1); fi
[ "$got" = "$sha" ] || { echo "zig.sh: $name.tar.xz is not the pinned file (sha256 $got, expected $sha)" >&2; exit 1; }
minisign -Vm "$work/$name.tar.xz" -P "$ZIG_PUBKEY" -x "$work/$name.tar.xz.minisig" >/dev/null ||
  { echo "zig.sh: the minisign signature of $name.tar.xz does not verify" >&2; exit 1; }

tar -xJf "$work/$name.tar.xz" -C "$work"
case "$os" in
  linux)
    mkdir -p /opt/zig
    rm -rf "/opt/zig/$ZIG_VERSION"
    mv "$work/$name" "/opt/zig/$ZIG_VERSION"
    ln -sf "/opt/zig/$ZIG_VERSION/zig" /usr/local/bin/zig ;;
  macos)
    dest=${RUNNER_TEMP:-/tmp}/zig
    rm -rf "$dest"
    mv "$work/$name" "$dest"
    if [ -n "${GITHUB_PATH:-}" ]; then echo "$dest" >> "$GITHUB_PATH"; fi ;;
esac
echo "zig.sh: Zig $ZIG_VERSION installed"

#!/usr/bin/env bash
# The tools of CI from .github/ci/mise.toml (docs/develop/ci.md, "The tools"): the one bootstrap download (mise itself,
# pinned by version and checksum below), then `mise install`. Nothing else names a tool's version.
#
#   mise.sh [ENV]            installs mise if it is not there at the pinned version, installs the tools of mise.toml
#                            (+ mise.ENV.toml: msrv, fuzz) and, in a workflow, puts them on the job's PATH and
#                            environment (GITHUB_PATH, GITHUB_ENV: RUSTUP_TOOLCHAIN, MSRV_TOOLCHAIN, NIGHTLY …)
#   mise.sh --image [ENV]    the same for an image build (no GITHUB_*): then `rustup default` is the pinned toolchain, so
#                            a shell with only PATH set (a container job) finds cargo and rustc
#   mise.sh --check          the pins agree: rust-toolchain.toml (when the repository has one) names mise.toml's Rust
#   mise.sh --self-test
#
# Environment: MISE_BIN_DIR (where mise goes, default $HOME/.local/bin), MISE_DATA_DIR (the tools' home, default mise's
# own; the bundle caches it). Run from anywhere in the repository. bash 3.2-safe (macOS).
set -euo pipefail

MISE_VERSION=2026.11.12
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

# the release's own SHASUMS256.txt, for the tarball of each platform
mise_asset() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  echo "linux-x64 4b029e19afc575875a4962dfe5d5e31cc93ab0317242768d0234adec219d3e14" ;;
    Linux-aarch64) echo "linux-arm64 9a125763f8445ea28d2da0e943fe5ad7d81b397d78f173cc07c1cc18ee2bee47" ;;
    Darwin-arm64)  echo "macos-arm64 f7bd19aa4e6b7a58d7296f98e2c6af68b2e2643dfd608b0bc46c2b5fdbc8749b" ;;
    Darwin-x86_64) echo "macos-x64 19c0e3dff9eddaab7a3519e9556be35580ade53b2bffb550f307343cb6b678ef" ;;
    *) echo "mise.sh: no mise for $(uname -s) $(uname -m)" >&2; return 1 ;;
  esac
}
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# the Rust version a mise.toml names (its `rust = { version = "…" …}` line)
rust_of() { sed -n 's/^rust = {[^}]*version = "\([^"]*\)".*/\1/p' "$1" | head -n 1; }

bootstrap() {
  local bin=${MISE_BIN_DIR:-$HOME/.local/bin} a asset sum tmp
  if [ -x "$bin/mise" ] && [ "$("$bin/mise" --version 2>/dev/null | awk '{print $1}')" = "$MISE_VERSION" ]; then return 0; fi
  a=$(mise_asset); asset=${a% *}; sum=${a#* }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/mise.XXXXXX")
  curl -fsSL --http1.1 --retry 5 --retry-all-errors --retry-delay 3 -o "$tmp/mise.tgz" \
    "https://github.com/jdx/mise/releases/download/v$MISE_VERSION/mise-v$MISE_VERSION-$asset.tar.gz"
  [ "$(sha256 "$tmp/mise.tgz")" = "$sum" ] || { echo "mise.sh: mise-v$MISE_VERSION-$asset.tar.gz is not the pinned file" >&2; rm -r "$tmp"; return 1; }
  tar -xzf "$tmp/mise.tgz" -C "$tmp"
  mkdir -p "$bin"
  mv "$tmp/mise/bin/mise" "$bin/mise"
  rm -r "$tmp"
  "$bin/mise" --version
}

check() {
  local want got f
  want=$(rust_of "$HERE/mise.toml")
  [ -n "$want" ] || { echo "mise.sh: mise.toml names no Rust version" >&2; return 1; }
  for f in "$ROOT/rust-toolchain.toml" "$ROOT/rust-toolchain"; do
    [ -f "$f" ] || continue
    got=$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' "$f" | head -n 1)
    [ "$got" = "$want" ] || { echo "mise.sh: ${f#"$ROOT"/} says $got, mise.toml says $want" >&2; return 1; }
  done
  echo "mise.sh: the pins agree (Rust $want)"
}

install() {
  local image=$1 envname=$2 bin=${MISE_BIN_DIR:-$HOME/.local/bin} p d orig_path=$PATH
  bootstrap
  export PATH="$bin:$PATH"
  [ -z "$envname" ] || export MISE_ENV=$envname
  cd "$HERE"
  export MISE_YES=1 MISE_TRUSTED_CONFIG_PATHS="$HERE"
  mise install
  if [ "$image" = 1 ]; then
    # a container job runs with the image's PATH only: the default toolchain is the pinned one
    eval "$(mise env -s bash)"
    rustup default "$(rust_of "$HERE/mise.toml")"
    rustc -V
    return 0
  fi
  eval "$(mise env -s bash)"
  if [ -n "${GITHUB_PATH:-}" ]; then
    # the directories mise (and its own bin) added to the PATH the job started with, for the job's later steps
    mise env --json | jq -r '.PATH // ""' | tr ':' '\n' | while read -r d; do
      [ -n "$d" ] || continue
      case ":$orig_path:" in *":$d:"*) ;; *) echo "$d" ;; esac
    done >> "$GITHUB_PATH"
  fi
  if [ -n "${GITHUB_ENV:-}" ]; then
    mise env --json | jq -r 'del(.PATH) | to_entries[] | "\(.key)=\(.value)"' >> "$GITHUB_ENV"
  fi
  rustc -V
  cargo --version
  p=$(command -v cargo-nextest || true); [ -z "$p" ] || cargo nextest --version | head -n 1
}

if [ "${1:-}" = --self-test ]; then
  rc=0 d=$(mktemp -d "${TMPDIR:-/tmp}/mise-test.XXXXXX")
  trap 'rm -r "$d"' EXIT
  fail() { echo "mise.sh self-test FAIL: $*"; rc=1; }
  [ "$(rust_of "$HERE/mise.toml")" != "" ] || fail "mise.toml names no Rust"
  [ "$(rust_of "$HERE/mise.msrv.toml")" = 1.95.0 ] || fail "mise.msrv.toml's Rust is $(rust_of "$HERE/mise.msrv.toml")"
  for p in Linux-x86_64 Linux-aarch64 Darwin-arm64 Darwin-x86_64; do
    case $p in Linux-x86_64) a="linux-x64" ;; Linux-aarch64) a="linux-arm64" ;; Darwin-arm64) a="macos-arm64" ;; *) a="macos-x64" ;; esac
    grep -q "$p) *echo \"$a [0-9a-f]\{64\}\"" "$0" || fail "no 64-digit checksum for $p"
  done
  # the pins agree with each other: a rust-toolchain.toml that names another channel fails --check
  mkdir -p "$d/ci" "$d/.github"
  printf '[tools]\nrust = { version = "1.100.0", profile = "minimal" }\n' > "$d/ci/mise.toml"
  [ "$(rust_of "$d/ci/mise.toml")" = 1.100.0 ] || fail "rust_of reads $(rust_of "$d/ci/mise.toml")"
  mkdir -p "$d/r/.github/ci"; cp "$0" "$d/r/.github/ci/mise.sh"; cp "$d/ci/mise.toml" "$d/r/.github/ci/mise.toml"
  printf '[toolchain]\nchannel = "1.100.0"\n' > "$d/r/rust-toolchain.toml"
  bash "$d/r/.github/ci/mise.sh" --check >/dev/null 2>&1 || fail "equal pins fail --check"
  printf '[toolchain]\nchannel = "1.99.1"\n' > "$d/r/rust-toolchain.toml"
  ! bash "$d/r/.github/ci/mise.sh" --check >/dev/null 2>&1 || fail "differing pins pass --check"
  rm "$d/r/rust-toolchain.toml"
  bash "$d/r/.github/ci/mise.sh" --check >/dev/null 2>&1 || fail "no rust-toolchain.toml fails --check"
  [ "$rc" = 0 ] && echo "mise.sh self-test: ok"
  exit $rc
fi

case ${1:-} in
  --check) check ;;
  --image) install 1 "${2:-}" ;;
  *) [ $# -le 1 ] || { echo "usage: mise.sh [ENV] | --image [ENV] | --check | --self-test" >&2; exit 2; }; install 0 "${1:-}" ;;
esac

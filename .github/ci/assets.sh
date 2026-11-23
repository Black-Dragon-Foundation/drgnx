#!/usr/bin/env bash
# The prebuilt assets of CI (docs/develop/ci.md, "Prebuilt images"): everything a job would download at setup, fetched
# once per input hash by `Test images` (images.yml) into a one-layer image on GHCR, and unpacked by the jobs in one step.
# The files are the same on every platform: the pinned model files (models.txt), the libghostty-vt tarballs (pin.toml),
# and the macOS Nidhogg tarball (nidhogg.sh's pin): data, not tools (the tools are mise's, .github/ci/mise.toml). A job
# that cannot pull the image (a fork's pull request, GHCR down) downloads them itself with the same scripts, which retry
# over HTTP/1.1.
#
#   assets.sh tag                  the image's tag: a hash of the files that hold the pins
#   assets.sh build DIR            downloads and checks everything into DIR/assets/ and packs DIR/assets.tar (the image's one file)
#   assets.sh use REF              pulls REF (ghcr.io/…/drgnx-assets@sha256:…; empty: nothing to do) and puts the files where
#                                  the setup scripts look: ../test-models (models.sh keeps files whose sums match),
#                                  crates/hub/ghostty-vt-sys/tarballs (fetch.sh), and NIDHOGG_DOWNLOADS (nidhogg.sh) in
#                                  $GITHUB_ENV. Always exits 0 when the files can still be downloaded.
#   assets.sh --self-test
#
# Environment: TOKEN and ACTOR (a token that reads the organisation's packages: ghcr.sh), ASSETS_TAR (use: a local tar
# instead of a pull; the self-test's), ASSETS_DIR (use: where it unpacks, default $RUNNER_TEMP/assets).
# Run from the repository's root. bash 3.2-safe (macOS).
set -eu -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
hash_of() { sha256 | cut -c1-16; }

# the files that hold the pins: an edit of any is a new tag
pin_files() {
  printf '%s\n' ".github/ci/models.txt" "crates/hub/ghostty-vt-sys/pin.toml" "test/container/nidhogg.sh"
}

tag() {
  local f
  ( cd "$ROOT"; for f in $(pin_files); do [ -f "$f" ] || { echo "assets.sh: no $f" >&2; exit 1; }; echo "$(sha256 "$f" | cut -d' ' -f1)  $f"; done ) | hash_of
}

curl_get() { curl -fsSL --http1.1 --retry 5 --retry-all-errors --retry-delay 3 -o "$1" "$2"; }

# VAR's value in a script (a line `VAR=value`)
pin() { sed -n "s/^$2=\\(.*\\)$/\\1/p" "$ROOT/$1" | head -n 1; }

build() {
  local dir=$1 a ver nurl asset f want got
  a=$dir/assets
  mkdir -p "$a/models" "$a/ghostty" "$a/downloads"
  bash "$HERE/models.sh" "$a/models"
  bash "$ROOT/crates/hub/ghostty-vt-sys/fetch.sh" "$a/ghostty"
  # (Zig and the other tools are mise's: .github/ci/mise.toml, not data)
  # Nidhogg for the Macs (the Linux jobs have it in their image)
  ver=$(pin test/container/nidhogg.sh NIDHOGG_VERSION); nurl=$(pin test/container/nidhogg.sh NIDHOGG_URL)
  asset=macos-arm64
  want=$(sed -n "s/^ *macos) *asset=[^;]*; *sha=\\([0-9a-f]*\\).*/\\1/p" "$ROOT/test/container/nidhogg.sh")
  [ -n "$want" ] || { echo "assets.sh: nidhogg.sh has no sum for macos" >&2; return 1; }
  f=nidhogg-$ver-$asset.tar.xz
  curl_get "$a/downloads/$f" "$nurl/v$ver/$f"
  got=$(sha256 "$a/downloads/$f" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "assets.sh: $f is not the pinned file ($got, not $want)" >&2; return 1; }
  # no .minisig of fetch.sh, no partial file
  find "$a" -name '*.new' -o -name '*.part' | grep -q . && { echo "assets.sh: a partial file is left in $a" >&2; return 1; }
  tar -cf "$dir/assets.tar" -C "$a" .
  printf 'FROM scratch\nCOPY assets.tar /assets.tar\n' > "$dir/Containerfile"
  echo "assets.sh: $(du -sk "$dir/assets.tar" | cut -f1) KiB in $dir/assets.tar"
}

use() {
  local ref=${1:-} dest tmp tar
  if [ -z "$ref" ] && [ -z "${ASSETS_TAR:-}" ]; then
    echo "::notice::no prebuilt assets (a fork's run, or GHCR has none yet): the setup downloads its files"
    return 0
  fi
  dest=${ASSETS_DIR:-${RUNNER_TEMP:-/tmp}/assets}
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/assets.XXXXXX")
  if [ -n "${ASSETS_TAR:-}" ]; then tar=$ASSETS_TAR
  elif bash "$HERE/ghcr.sh" file "$ref" assets.tar "$tmp"; then tar=$tmp/assets.tar
  else echo "::warning::the prebuilt assets $ref could not be pulled: the setup downloads its files"; rm -r "$tmp"; return 0; fi
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xf "$tar" -C "$dest"
  rm -r "$tmp"
  # the models beside the checkout (DRGNX_TEST_MODELS is set from there by the job), checked by models.sh
  if [ -d "$dest/models" ]; then mkdir -p "$ROOT/../test-models"; cp -R "$dest/models/." "$ROOT/../test-models/"; fi
  if [ -d "$dest/ghostty" ]; then mkdir -p "$ROOT/crates/hub/ghostty-vt-sys/tarballs"; cp "$dest"/ghostty/* "$ROOT/crates/hub/ghostty-vt-sys/tarballs/"; fi
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "NIDHOGG_DOWNLOADS=$dest/downloads" >> "$GITHUB_ENV"
  fi
  echo "assets.sh: the prebuilt assets are in $dest (models, libghostty-vt and Nidhogg tarballs)"
}

if [ "${1:-}" = --self-test ]; then
  rc=0 d=$(mktemp -d "${TMPDIR:-/tmp}/assets-test.XXXXXX")
  trap 'rm -r "$d"' EXIT
  fail() { echo "assets.sh self-test FAIL: $*"; rc=1; }
  t=$(tag) || fail "tag"
  case $t in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) fail "the tag is not 16 hex digits: $t" ;; esac
  [ "$(tag)" = "$t" ] || fail "the tag is not stable"
  # a tarball in the image's layout lands where the setup scripts look, and the environment names the downloads
  mkdir -p "$d/pack/models/m1" "$d/pack/ghostty" "$d/pack/downloads" "$d/root/.github/ci" "$d/root/crates/hub/ghostty-vt-sys" "$d/root/checkout/.github/ci"
  echo model > "$d/pack/models/m1/model.safetensors"; echo gh > "$d/pack/ghostty/libghostty-vt-1.0.0.tar.gz"; echo zig > "$d/pack/downloads/zig-x.tar.xz"
  tar -cf "$d/assets.tar" -C "$d/pack" .
  mkdir -p "$d/checkout/.github/ci"
  cp "$0" "$d/checkout/.github/ci/assets.sh"
  : > "$d/env"
  ( cd "$d/checkout" && ASSETS_TAR="$d/assets.tar" ASSETS_DIR="$d/unpacked" GITHUB_ENV="$d/env" bash .github/ci/assets.sh use "" >/dev/null ) || fail "use exited $?"
  [ -f "$d/test-models/m1/model.safetensors" ] || fail "the models are not beside the checkout"
  [ -f "$d/checkout/crates/hub/ghostty-vt-sys/tarballs/libghostty-vt-1.0.0.tar.gz" ] || fail "the ghostty tarball is not in the crate"
  grep -q "^NIDHOGG_DOWNLOADS=$d/unpacked/downloads$" "$d/env" || fail "NIDHOGG_DOWNLOADS is not set"
  # no reference and no tar: nothing to do, exit 0 (the setup downloads)
  ( cd "$d/checkout" && bash .github/ci/assets.sh use "" 2>&1 | grep -q 'no prebuilt assets' ) || fail "an empty ref is not a notice"
  # an unpullable reference is a warning, not a failure
  ( cd "$d/checkout" && bash .github/ci/assets.sh use "ghcr.io/not-this-org/x@sha256:00" 2>&1 | grep -q 'could not be pulled' ) || fail "a bad ref is not a warning"
  [ "$rc" = 0 ] && echo "assets.sh self-test: ok"
  exit $rc
fi

case ${1:-} in
  tag) [ $# = 1 ] || exit 2; tag ;;
  build) [ $# = 2 ] || exit 2; build "$2" ;;
  use) [ $# = 2 ] || exit 2; use "$2" ;;
  *) echo "usage: assets.sh tag | build DIR | use REF | --self-test" >&2; exit 2 ;;
esac

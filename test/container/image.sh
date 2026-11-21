#!/usr/bin/env bash
# The image a local test run uses, without building it again and again: the local store first, then GHCR's copy of the
# same tag (the CI images, `Test images`), a build only when both miss.  The image is named NAME:TAG, TAG from
# image-tag.sh (a hash of the Containerfile and every file it copies), as CI publishes it.
#   image.sh RUNTIME NAME CONTAINERFILE [BUILD-OPTION...]
# Prints the image reference on stdout and `image: REF (local|pulled|built)` on stderr; BUILD-OPTIONs go to the build
# (--build-arg …).  The build is capped like the runs (DRGNX_TEST_BUILD_MEMORY, default 3g; podman only, as docker's
# buildx ignores --memory).
#   DRGNX_TEST_IMAGE_PULL=0           never pull (offline); a miss builds
#   DRGNX_TEST_IMAGE_PULL_TIMEOUT=N   seconds a pull may take (default 180); a slow or failed pull builds
# The pull is anonymous: the CI images are public.  bash 3.2-safe.  docs/develop/ci.md, "Local runs"
set -eu -o pipefail
[ $# -ge 3 ] || { echo "usage: image.sh RUNTIME NAME CONTAINERFILE [BUILD-OPTION...]" >&2; exit 2; }
rt=$1 name=$2 file=$3
shift 3
here=$(cd "$(dirname "$0")" && pwd)

tag=$(bash "$here/image-tag.sh" "$file")
image="$name:$tag"
remote="ghcr.io/black-dragon-foundation/$name:$tag"

if "$rt" image inspect "$image" >/dev/null 2>&1; then
  echo "image: $image (local)" >&2
  echo "$image"; exit 0
fi

if [ "${DRGNX_TEST_IMAGE_PULL:-1}" != 0 ]; then
  limit=()
  if command -v timeout >/dev/null 2>&1; then limit=(timeout "${DRGNX_TEST_IMAGE_PULL_TIMEOUT:-180}")
  elif command -v gtimeout >/dev/null 2>&1; then limit=(gtimeout "${DRGNX_TEST_IMAGE_PULL_TIMEOUT:-180}"); fi
  if ${limit[@]+"${limit[@]}"} "$rt" pull -q "$remote" >/dev/null 2>&1 && "$rt" tag "$remote" "$image" >/dev/null 2>&1; then
    echo "image: $image (pulled)" >&2
    echo "$image"; exit 0
  fi
fi

# an image on a base (a line `# base: NAME FILE`, as image-tag.sh reads it) is built FROM the base, which is resolved
# the same way: local, pulled, built
base=$(awk '$1 == "#" && $2 == "base:" { print $3, $4; exit }' "$file")
if [ -n "$base" ]; then
  set -- --build-arg "BASE=$(bash "$0" "$rt" "${base% *}" "$(dirname "$file")/${base#* }" "$@")" "$@"
fi

bargs=()
[ "$rt" != podman ] || bargs=(--memory "${DRGNX_TEST_BUILD_MEMORY:-3g}" --memory-swap "${DRGNX_TEST_BUILD_MEMORY:-3g}")
"$rt" build ${bargs[@]+"${bargs[@]}"} -q -t "$image" "$@" -f "$file" "$(dirname "$file")" >/dev/null
echo "image: $image (built)" >&2
echo "$image"

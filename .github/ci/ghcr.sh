#!/usr/bin/env bash
# The prebuilt CI images on GHCR (`Test images`, .github/workflows/images.yml), read through the registry API with
# curl alone (the arm64 and 26.04 runners need neither podman nor skopeo for it).
#   ghcr.sh ref NAME TAG              ghcr.io/black-dragon-foundation/NAME@sha256:… for that tag, or nothing when GHCR
#                                     has none (the caller builds the image itself)
#   ghcr.sh file REF PATH DEST        the file PATH of the one-layer image REF (NAME@sha256:…, `FROM scratch` + one
#                                     COPY) into the directory DEST, the manifest and the layer checked against their
#                                     digests
# TOKEN and ACTOR: a token that reads the organisation's packages (a job's github.token with packages: read). Both
# go to curl on its standard input, never on a command line. Exit 0 with nothing printed when `ref` finds no image
# (a notice; a warning when GHCR refuses or does not answer), 1 when `file` fails, 2 on a usage error.
# docs/develop/ci.md, "Prebuilt images"
set -eu -o pipefail

org=black-dragon-foundation
accept="application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"

bearer() { # NAME — a pull token for that package
  printf 'user = "%s:%s"\n' "$ACTOR" "$TOKEN" |
    curl -fsS --retry 3 -K - "https://ghcr.io/token?service=ghcr.io&scope=repository:$org/$1:pull" | jq -r .token
}
api() { # BEARER URL [CURL ARGS...] — a registry request with that token
  local b=$1 url=$2; shift 2
  printf 'header = "Authorization: Bearer %s"\n' "$b" | curl -sS --retry 3 -K - -H "Accept: $accept" "$@" "$url"
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else shasum -a 256 | cut -c1-64; fi; }

case "${1:-}" in
  ref)
    [ $# = 3 ] || { echo "usage: ghcr.sh ref NAME TAG" >&2; exit 2; }
    name=$2 tag=$3
    b=$(bearer "$name" 2>/dev/null) || { echo "::warning::no GHCR token for $name: it is built here" >&2; exit 0; }
    hdr=$(mktemp)
    code=$(api "$b" "https://ghcr.io/v2/$org/$name/manifests/$tag" -I -o /dev/null -D "$hdr" -w '%{http_code}') || code=000
    digest=$(tr -d '\r' < "$hdr" | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p' | head -n 1)
    rm -f "$hdr"
    if [ "$code" = 200 ] && [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "ghcr.io/$org/$name@$digest"
    elif [ "$code" = 404 ]; then
      echo "::notice::no $name:$tag on GHCR yet: it is built here" >&2
    else   # a token without packages: read, or GHCR down: the run still works, slower
      echo "::warning::GHCR answered HTTP $code for $name:$tag: it is built here" >&2
    fi
    ;;
  file)
    [ $# = 4 ] || { echo "usage: ghcr.sh file REF PATH DEST" >&2; exit 2; }
    ref=$2 path=$3 dest=$4
    [[ $ref =~ ^ghcr\.io/$org/([a-z0-9-]+)@(sha256:[0-9a-f]{64})$ ]] || { echo "ghcr.sh: $ref is not $org/NAME@sha256:…" >&2; exit 2; }
    name=${BASH_REMATCH[1]} digest=${BASH_REMATCH[2]}
    b=$(bearer "$name")
    work=$(mktemp -d)
    trap 'rm -r "$work"' EXIT
    api "$b" "https://ghcr.io/v2/$org/$name/manifests/$digest" -f -o "$work/manifest"
    [ "sha256:$(sha < "$work/manifest")" = "$digest" ] || { echo "ghcr.sh: the manifest of $ref does not match its digest" >&2; exit 1; }
    [ "$(jq '.layers | length' "$work/manifest")" = 1 ] || { echo "ghcr.sh: $ref is not a one-layer image" >&2; exit 1; }
    layer=$(jq -r '.layers[0].digest' "$work/manifest")
    # the blob redirects to storage: curl sends the Authorization header to GHCR only, never to another host
    api "$b" "https://ghcr.io/v2/$org/$name/blobs/$layer" -f -L -o "$work/layer"
    [ "sha256:$(sha < "$work/layer")" = "$layer" ] || { echo "ghcr.sh: the layer of $ref does not match its digest" >&2; exit 1; }
    mkdir -p "$dest"
    tar -xf "$work/layer" -C "$dest" "$path"
    ;;
  *) echo "usage: ghcr.sh ref NAME TAG | file REF PATH DEST" >&2; exit 2 ;;
esac

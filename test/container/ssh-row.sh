#!/usr/bin/env bash
# drgnx-slot: runs its own container
# test/container/ssh-row.sh: the remote-terminal rows (test/ssh/*-test.el) in the batch tier, on an image of their own:
# the test image named by DRGNX_TEST_IMAGE (the line's) plus Containerfile.ssh (sshd, ssh, tcsh, sudo, tic), tagged
# drgnx-test-ssh:<16 hex of a sha256 over Containerfile.ssh and the base's image id>, built when missing.  The tests
# start sshd on 127.0.0.1 inside the container and make every key and user there, per run; nothing is kept.
#   DRGNX_TEST_IMAGE=IMAGE test/container/ssh-row.sh
# DRGNX_SSH_ROW_DNF_CACHE=DIR: the build's dnf cache (mounted at /var/cache/libdnf5), as the other local images use.
# Exit 75 "image refused" when the image cannot be had (no base, a failed build, no sshd in it): never a skip.
# Otherwise `bin/drgnx test --container`'s exit.  docs/develop/terminal.md, "Remote terminals".
set -uo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
refuse() { echo "ssh-row: image refused: $*" >&2; exit 75; }
base=${DRGNX_TEST_IMAGE:-}
[ -n "$base" ] || refuse "DRGNX_TEST_IMAGE names no test image"
base_id=$(podman image inspect -f '{{.Id}}' "$base" 2>/dev/null) || refuse "no image $base"
tag=$({ cat "$here/test/container/Containerfile.ssh"; echo "$base_id"; } | sha256sum | cut -c1-16)
image=localhost/drgnx-test-ssh:$tag
if ! podman image inspect "$image" >/dev/null 2>&1; then
  cache=()
  if [ -n "${DRGNX_SSH_ROW_DNF_CACHE:-}" ]; then
    mkdir -p "$DRGNX_SSH_ROW_DNF_CACHE" && cache=(-v "$DRGNX_SSH_ROW_DNF_CACHE:/var/cache/libdnf5:Z")
  fi
  podman build -q --memory 3g --build-arg "BASE=$base" ${cache[@]+"${cache[@]}"} -t "$image" \
    -f "$here/test/container/Containerfile.ssh" "$here/test/container" >/dev/null || refuse "the build of $image failed"
fi
podman run --rm "$image" test -x /usr/sbin/sshd || refuse "$image has no sshd"
echo "ssh-row: $image" >&2
cd "$here" && DRGNX_TEST_IMAGE=$image DRGNX_TEST_ONLY=/src/test/ssh DRGNX_TEST_SELECTOR="${DRGNX_TEST_SELECTOR:-\"^drgnx-term-ssh/\"}" exec bin/drgnx test --container

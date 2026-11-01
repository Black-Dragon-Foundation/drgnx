#!/bin/sh
# Install the pinned child-frame packages (test/fixtures/childframe-packages.eld: versions and sha256 of each archive)
# into DIR/elpa, inside the GUI test image so the byte code matches the Emacs the tests run on; only DIR is written.
# Usage: childframe-elpa.sh DIR  (DIR must not exist yet).  Then run the GUI tier with DRGNX_CHILDFRAME_ELPA=DIR/elpa
# (docs/develop/harness.md, "Child-frame packages").  DRGNX_CONTAINER: the runtime (default podman);
# DRGNX_TEST_GUI_IMAGE: the image (default drgnx-test-gui:f45).
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
dir=${1:?usage: childframe-elpa.sh DIR}
[ ! -e "$dir" ] || { echo "childframe-elpa: $dir exists already" >&2; exit 1; }
rt=${DRGNX_CONTAINER:-podman}
image=${DRGNX_TEST_GUI_IMAGE:-drgnx-test-gui:f45}
mkdir -p "$dir"
trap 'rm -rf "$dir"' EXIT
"$rt" run --rm --security-opt seccomp=unconfined --security-opt label=disable --memory 2g \
  -e DRGNX_EMACS=/usr/local/bin/emacs -v "$root:/src:ro" -v "$(cd "$dir" && pwd -P):/out" -w /src "$image" \
  bin/drgnx childframe-elpa /out/elpa
[ -d "$dir/elpa" ] || { echo "childframe-elpa: the install made no $dir/elpa" >&2; exit 1; }
trap - EXIT

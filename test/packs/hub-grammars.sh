#!/usr/bin/env bash
# The pack-built grammars the hub's tests parse with (language packs Task 6a): builds the hub's nine built-in packs'
# grammars with the pack job (`ratatoskr packs sync --builtin`) into CACHE/KEY, KEY being a hash of their pins, and
# prints the two variables a test run needs. An unchanged set of pins reuses the folder; a pin change builds a new one.
# Needs network, git and a C compiler: run it in a container (never on the host). Usage:
#   eval "$(bash test/packs/hub-grammars.sh CACHE)"      # sets DRGNX_PACK_LOCK and DRGNX_PACK_GRAMMARS
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cache=${1:?usage: hub-grammars.sh CACHE}
packs="rust c shell python javascript typescript tsx go java"
key=$(for p in $packs; do grep -ho ':\(commit\|tree-sha256\|src\) "[^"]*"' "$here/packs/$p/pack.eld"; done | sha256sum | cut -c1-16)
dir="$cache/$key"
if [ ! -f "$dir/drgnx.lock.eld" ]; then
  mkdir -p "$cache"
  tmp="$(mktemp -d "$cache/.build.XXXXXX")"
  trap 'rm -rf -- "$tmp"' EXIT
  (cd "$here/runtime" && cargo run --locked -q -p drgnx-ratatoskr --bin ratatoskr -- packs sync --builtin "$tmp" $packs) >&2
  # a run that built the same key at the same time wins; ours is dropped
  mv -T "$tmp" "$dir" 2>/dev/null || true
fi
echo "export DRGNX_PACK_LOCK='$dir/drgnx.lock.eld' DRGNX_PACK_GRAMMARS='$dir/grammars'"

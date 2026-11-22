#!/usr/bin/env bash
# The python tree-sitter grammar the Emacs unit tests that need a real parser load (the notebook's), built by the pack job
# (`ratatoskr packs sync --builtin`) at the pack's pin into CACHE/python-KEY, KEY a hash of the pin: an unchanged pin reuses
# the folder. Needs the hub's binary (DRGNX_RATATOSKR_BIN, else target/debug/ratatoskr), network, git and a C
# compiler: the unit tier's container has them, so `bin/drgnx test --container` runs this first (the cache is a host folder
# mounted into it). Usage:
#   test/packs/ts-grammars.sh CACHE                      prints `export DRGNX_TEST_TS_GRAMMARS=DIR` (nothing without a grammar)
#   test/packs/ts-grammars.sh CACHE --then CMD...        the same variable set, then CMD run
# Without a grammar the notebook's real-parser test skips, unless DRGNX_TEST_TS_REQUIRED is set (CI): then this fails.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cache=${1:?usage: ts-grammars.sh CACHE [--then CMD...]}
shift
bin="${DRGNX_RATATOSKR_BIN:-$here/target/debug/ratatoskr}"
key=$(grep -ho ':\(commit\|tree-sha256\|src\) "[^"]*"' "$here/packs/python/pack.eld" | sha256sum | cut -c1-16)
dir="$cache/python-$key"
if [ ! -d "$dir/grammars" ] && [ -x "$bin" ]; then
  mkdir -p "$cache"
  tmp="$(mktemp -d "$cache/.build.XXXXXX")"
  trap 'rm -rf -- "$tmp"' EXIT
  if "$bin" packs sync --builtin "$tmp" python >&2; then
    mv -T "$tmp" "$dir" 2>/dev/null || true     # a run that built the same key at the same time wins; ours is dropped
  fi
fi
lib="$(ls "$dir"/grammars/python/*/libtree-sitter-python.so 2>/dev/null | head -n 1 || true)"
if [ -n "$lib" ]; then
  export DRGNX_TEST_TS_GRAMMARS="$(dirname "$lib")"
elif [ -n "${DRGNX_TEST_TS_REQUIRED:-}" ]; then
  echo "ts-grammars.sh: no python grammar (the pack job did not build one at $dir; hub binary: $bin)" >&2
  exit 1
else
  echo "ts-grammars.sh: no python grammar (no hub binary at $bin, or the pack job failed): the real-parser test skips" >&2
fi
if [ "${1:-}" = --then ]; then
  shift
  exec "$@"
fi
[ -z "${DRGNX_TEST_TS_GRAMMARS:-}" ] || echo "export DRGNX_TEST_TS_GRAMMARS='$DRGNX_TEST_TS_GRAMMARS'"

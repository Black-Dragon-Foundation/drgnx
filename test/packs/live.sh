#!/usr/bin/env bash
# The language packs, for real (needs network, git and a C compiler): install the new grammar packs with
# `drgnx packs sync` (each grammar is fetched at its pin, built, load-checked in a child and its queries compiled),
# then open each pack's sample in a batch Emacs and check its mode and the faces of a few tokens.
# Run it in a container (never on the host): .claude/tmp/ctr.sh -- bash test/packs/live.sh   (docs/develop/packs.md)
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# DRGNX_PACKS_LIVE_KEEP=DIR keeps the built data in DIR (empty or new) for test/packs/gui.sh's screenshots
if [ -n "${DRGNX_PACKS_LIVE_KEEP:-}" ]; then root="$DRGNX_PACKS_LIVE_KEEP"; mkdir -p "$root"
else root="$(mktemp -d "${TMPDIR:-/tmp}/drgnx-packs-live.XXXXXX")"; trap 'rm -rf -- "$root"' EXIT; fi
export DRGNX_DATA_DIR="$root/data" DRGNX_CONFIG_DIR="$root/config" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache"
mkdir -p "$root/data/bin" "$root/config"
(cd "$here/runtime" && cargo build --locked -q -p drgnx-ratatoskr --bin ratatoskr)
cp "$here/runtime/target/debug/ratatoskr" "$root/data/bin/ratatoskr"
export DRGNX_RATATOSKR_BIN="$root/data/bin/ratatoskr"
packs=${*:-php elixir haskell kotlin swift zig sql}
"$here/bin/drgnx" packs sync --add $packs
"$here/bin/drgnx" packs list | grep -E "installed"
"${DRGNX_EMACS:-$(command -v emacs)}" --batch -Q -L "$here/core" -L "$here/modules/lang" -L "$here/wb" -L "$here/test/fixtures" \
  --eval "(setq load-prefer-newer t drgnx-dir \"$here/\")" -l ert -l "$here/test/packs/live-test.el" \
  -f ert-run-tests-batch-and-exit

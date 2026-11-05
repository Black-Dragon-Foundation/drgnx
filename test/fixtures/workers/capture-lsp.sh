#!/usr/bin/env bash
# Record rust-analyzer's, clangd's and tsserver's (typescript-language-server's) traffic for the perf lab's LSP workloads.
# Run ONCE, in the container, from the repo root (the outputs are committed):
#   .claude/tmp/ctr.sh --image localhost/drgnx-dev:f45 --memory 6g -- bash test/fixtures/workers/capture-lsp.sh
# A server the image lacks is installed for this run only (the container is thrown away; the image does not change):
# dnf for clangd and rust-analyzer (with cargo and rust-src, which rust-analyzer needs to index std), dnf nodejs and npm
# for typescript-language-server.  The projects are test/fixtures/workers/lsp-projects/*; the clients and their
# positions are in capture-lsp.el.  Outputs: corpus-NAME.eld.gz and manifest.eld (message count and byte total of
# what a full replay sends: test/unit/perf-workers-test.el replays each corpus and compares).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
cp -r "$here/lsp-projects" "$work/projects"
need=()
command -v clangd >/dev/null || need+=(clang-tools-extra)
command -v rust-analyzer >/dev/null || need+=(rust-analyzer)
command -v cargo >/dev/null || need+=(cargo rust-src)
command -v node >/dev/null || need+=(nodejs npm)
if [ ${#need[@]} -gt 0 ]; then
  echo "capture-lsp: installing for this run only: ${need[*]}" >&2
  dnf -y -q install "${need[@]}" >&2
fi
if ! command -v typescript-language-server >/dev/null; then
  npm install --silent --prefix "$work/npm" typescript typescript-language-server >&2
  export PATH="$work/npm/node_modules/.bin:$PATH"
fi
# the server looks for `typescript' in the workspace (in the temporary copy of the project, not in the repository)
# (5.x: 7.x is the native compiler and has no tsserver.js, which typescript-language-server drives)
[ -d "$work/projects/ts/node_modules/typescript" ] || npm install --silent --prefix "$work/projects/ts" typescript@5 >&2
only=" ${*:-rust c ts} "   # capture-lsp.sh [NAME…]: just those servers (the manifest is rewritten either way)
capture() {   # NAME COMMAND FILE LANG POSITIONS QUIET
  case "$only" in *" $1 "*) ;; *) return 0 ;; esac
  LSP_CAPTURE_NAME=$1 LSP_CAPTURE_CMD=$2 LSP_CAPTURE_ROOT="$work/projects/$1" LSP_CAPTURE_FILE=$3 LSP_CAPTURE_LANG=$4 \
    LSP_CAPTURE_POSITIONS=$5 LSP_CAPTURE_QUIET=$6 LSP_CAPTURE_OUT="$here/corpus-$1.eld.gz" \
    emacs --batch -Q -l "$here/capture-lsp.el"
}
(cd "$work/projects/rust" && cargo fetch -q 2>/dev/null || true)
capture rust rust-analyzer src/main.rs rust 16:6,16:4 12
capture c clangd main.c c 10:5,10:2 4
capture ts "typescript-language-server --stdio" index.ts typescript 4:6,4:0 5
LSP_REPLAY_LIBRARY=1 emacs --batch -Q -l "$here/../lsp-replay.el" -l "$here/write-manifest.el"
cat "$here/manifest.eld"

#!/usr/bin/env bash
# commit-times.sh BUILT_FROM: each tracked file of the checkout (the current directory) gets its last commit's time as
# its mtime, so cargo, which rebuilds a crate when a source is newer than its last build, sees a file a restored
# runtime/target was built from as unchanged (a fresh checkout gives every file the checkout's time: everything
# rebuilt).  BUILT_FROM is the file holding the commit the restored target was built from (written before the save):
# a file that differs from that commit keeps the checkout's time, since its last commit can be older than the cached
# build (a branch committed before main's run) and it must still rebuild.  No such file, or a commit not in the
# history: every file keeps the checkout's time.  Files git does not track keep theirs (newer than the cache).  Needs
# the whole history (checkout fetch-depth: 0; a shallow history leaves the files it does not reach new).  bash
# 3.2-safe; GNU and BSD date and touch.  docs/develop/ci.md, "What is cached"
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: commit-times.sh BUILT_FROM" >&2; exit 2; }
export TZ=UTC
# a container job's root runs git in the runner user's checkout; paths as they are, never quoted
g() { git -c safe.directory="$PWD" -c core.quotePath=false "$@"; }
from=$(cat "$1" 2>/dev/null || true)
if [ -z "$from" ] || ! g cat-file -e "$from^{commit}" 2>/dev/null; then
  echo "commit-times: no known commit the cache was built from: every file keeps the checkout's time"
  exit 0
fi
changed=$(mktemp)
trap 'rm -f "$changed"' EXIT
g diff --name-only "$from" HEAD > "$changed"
stamp() { date -u -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -u -r "$1" +%Y%m%d%H%M.%S; }
n=0 prev="" files=()
flush() {
  [ "${#files[@]}" -eq 0 ] || touch -c -t "$(stamp "$prev")" -- "${files[@]}"
  n=$((n + ${#files[@]})) files=()
}
# newest first: a path's first appearance is its last commit; one touch per commit time
while IFS="$(printf '\t')" read -r t f; do
  [ -f "$f" ] || continue
  [ "$t" = "$prev" ] || { flush; prev=$t; }
  files+=("$f")
done < <(g log --format='T %ct' --name-only HEAD |
         awk -v changed="$changed" 'BEGIN { while ((getline f < changed) > 0) skip[f] = 1 }
                                    /^T / { t = $2; next }
                                    NF && !($0 in seen) { seen[$0] = 1; if (!($0 in skip)) print t "\t" $0 }')
flush
echo "commit-times: $n files at their last commit's time; $(wc -l < "$changed" | tr -d ' ') changed since ${from:0:12} keep the checkout's"

#!/usr/bin/env bash
# Is gleipnir's Seatbelt base still Codex's? Usage: sbpl-upstream.sh OURS UPSTREAM  (two files).
# Both are compared from their `(version 1)` line on, so our licence header is not a difference.
# Exit 0: the same. Exit 1: they differ (the diff is printed, with an ::error:: line). Exit 2: a file is missing or has
# no `(version 1)` line (a page that moved, an error body): never read as "the same".
# docs/develop/ci.md (SBPL upstream), docs/develop/gleipnir.md (the Seatbelt base)
set -u
ours=${1:?usage: sbpl-upstream.sh OURS UPSTREAM}
upstream=${2:?usage: sbpl-upstream.sh OURS UPSTREAM}
body() {
  [ -s "$1" ] || { echo "::error::$1 is missing or empty" >&2; return 2; }
  grep -q '^(version 1)' "$1" || { echo "::error::$1 has no (version 1) line: not a Seatbelt profile" >&2; return 2; }
  sed -n '/^(version 1)/,$p' "$1"
}
a=$(mktemp) && b=$(mktemp) || exit 2
trap 'rm -f "$a" "$b"' EXIT
body "$ours" > "$a" || exit 2
body "$upstream" > "$b" || exit 2
if diff -u --label ours --label upstream "$a" "$b"; then
  echo "base.sbpl matches upstream"
else
  echo "::error::Codex's upstream Seatbelt base profile differs from gleipnir's base.sbpl: re-check it (docs/develop/gleipnir.md)"
  exit 1
fi

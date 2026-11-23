#!/usr/bin/env bash
# After a run's saves: delete this ref's superseded target caches (docs/develop/ci.md, "What is cached").  Each commit's
# run saves a new entry per job (cache-key.sh ends its key in the commit), so a ref's older entries of a job, toolchain
# and lock are dead weight inside the repository's 10 GB.  For each prefix (a key without its `-SHA12`) it keeps the
# newest entry and deletes the rest; only entries of this ref, only `cargo-…-mt1-…-SHA12` keys (never the registry,
# models, Nidhogg or corpus), and a prefix with one entry is left alone.  Every decision is logged.
#
#   cache-prune.sh              REPO, REF (github.ref) and GH_TOKEN (actions: write) from the environment
#   cache-prune.sh --dry-run    the same, deleting nothing
#   cache-prune.sh --self-test  the rule over a fixture listing
#
# LISTING=FILE reads a saved `gh api --paginate …/actions/caches` instead of the API (the self-test's input).
# bash 3.2-safe; needs gh and jq.
set -uo pipefail

# the decisions over a listing: `keep|delete ID KEY`, one a line
decide() {
  jq -r --arg ref "$2" '.actions_caches[]?
      | select(.ref == $ref and (.key | startswith("cargo-registry-") | not) and (.key | test("^cargo-.*-mt1-.*-[0-9a-f]{12}$")))
      | [(.key | sub("-[0-9a-f]{12}$"; "")), .created_at, (.id | tostring), .key] | @tsv' "$1" |
    LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2r -k3,3nr |
    awk -F '\t' '{ print ($1 == prev ? "delete" : "keep"), $3, $4; prev = $1 }'
}

if [ "${1:-}" = --self-test ]; then
  rc=0 d=$(mktemp -d "${TMPDIR:-/tmp}/cache-prune-test.XXXXXX")
  trap 'rm -r "$d"' EXIT
  p=cargo-Linux-X64-fedora45-mt1-rustc-1.100.0-abc-2026-11-01-86eb008250d4212c
  cat > "$d/l.json" <<JSON
{"actions_caches": [
 {"id": 1, "key": "$p-aaaaaaaaaaaa", "ref": "refs/heads/ci/flow", "created_at": "2026-11-23T10:00:00Z"},
 {"id": 2, "key": "$p-bbbbbbbbbbbb", "ref": "refs/heads/ci/flow", "created_at": "2026-11-23T11:00:00Z"},
 {"id": 3, "key": "$p-cccccccccccc", "ref": "refs/heads/ci/flow", "created_at": "2026-11-23T12:00:00Z"},
 {"id": 4, "key": "$p-dddddddddddd", "ref": "refs/heads/main", "created_at": "2026-11-22T09:00:00Z"},
 {"id": 5, "key": "$p-eeeeeeeeeeee", "ref": "refs/heads/main", "created_at": "2026-11-22T10:00:00Z"},
 {"id": 6, "key": "cargo-Linux-X64-msrv195-mt1-rustc-1.95.0-abc-2026-11-01-86eb008250d4212c-aaaaaaaaaaaa", "ref": "refs/heads/ci/flow", "created_at": "2026-11-23T10:00:00Z"},
 {"id": 7, "key": "cargo-Linux-X64-fedora45-mt1-rustc-1.99.1-abc-2026-10-01-86eb008250d4212c-aaaaaaaaaaaa", "ref": "refs/heads/ci/flow", "created_at": "2026-11-20T10:00:00Z"},
 {"id": 8, "key": "cargo-registry-Linux-1234567890ab", "ref": "refs/heads/ci/flow", "created_at": "2026-11-23T10:00:00Z"},
 {"id": 9, "key": "cargo-registry-Linux-1234567890ac", "ref": "refs/heads/ci/flow", "created_at": "2026-11-23T11:00:00Z"},
 {"id": 10, "key": "models-0123456789abcdef", "ref": "refs/heads/ci/flow", "created_at": "2026-11-23T10:00:00Z"},
 {"id": 11, "key": "cargo-Linux-fedora45-mt1-rustc-1.99.1-abc-2026-10-01-0123456789012345678901234567890123456789012345678901234567890123", "ref": "refs/heads/ci/flow", "created_at": "2026-11-20T10:00:00Z"},
 {"id": 12, "key": "cargo-Linux-fedora45-mt1-rustc-1.99.1-abc-2026-10-01-0123456789012345678901234567890123456789012345678901234567890124", "ref": "refs/heads/ci/flow", "created_at": "2026-11-21T10:00:00Z"},
 {"id": 13, "key": "$p-ffffffffffff", "ref": "refs/pull/5/merge", "created_at": "2026-11-23T13:00:00Z"}
]}
{"actions_caches": [
 {"id": 14, "key": "$p-999999999999", "ref": "refs/heads/ci/flow", "created_at": "2026-11-23T09:00:00Z"}
]}
JSON
  got=$(decide "$d/l.json" refs/heads/ci/flow | LC_ALL=C sort -k2,2n | tr '\n' ';')
  want="delete 1 $p-aaaaaaaaaaaa;delete 2 $p-bbbbbbbbbbbb;keep 3 $p-cccccccccccc;keep 6 cargo-Linux-X64-msrv195-mt1-rustc-1.95.0-abc-2026-11-01-86eb008250d4212c-aaaaaaaaaaaa;keep 7 cargo-Linux-X64-fedora45-mt1-rustc-1.99.1-abc-2026-10-01-86eb008250d4212c-aaaaaaaaaaaa;delete 14 $p-999999999999;"
  [ "$got" = "$want" ] || { echo "cache-prune.sh self-test FAIL: ci/flow: '$got'"; rc=1; }
  got=$(decide "$d/l.json" refs/heads/main | tr '\n' ';')
  [ "$got" = "keep 5 $p-eeeeeeeeeeee;delete 4 $p-dddddddddddd;" ] || { echo "cache-prune.sh self-test FAIL: main: '$got'"; rc=1; }
  got=$(decide "$d/l.json" refs/heads/line/x | tr '\n' ';')
  [ -z "$got" ] || { echo "cache-prune.sh self-test FAIL: an unknown ref decides '$got'"; rc=1; }
  [ "$rc" = 0 ] && echo "cache-prune.sh self-test: ok"
  exit $rc
fi

dry=0
case ${1:-} in --dry-run) dry=1; shift ;; esac
[ $# -eq 0 ] || { echo "usage: cache-prune.sh [--dry-run] | --self-test" >&2; exit 2; }
: "${REF:?cache-prune.sh: REF}"
listing=${LISTING:-}
if [ -z "$listing" ]; then
  : "${REPO:?cache-prune.sh: REPO}"
  listing=$(mktemp "${TMPDIR:-/tmp}/cache-prune.XXXXXX")
  trap 'rm -f "$listing"' EXIT
  gh api --paginate "repos/$REPO/actions/caches?ref=$REF&per_page=100" > "$listing" || { echo "::warning::cache-prune.sh: the cache list could not be read; nothing pruned"; exit 0; }
fi
kept=0 deleted=0 failed=0
while read -r verb id key; do
  [ -n "$verb" ] || continue
  if [ "$verb" = keep ]; then kept=$((kept + 1)); echo "keep   $id $key"; continue; fi
  if [ "$dry" = 1 ]; then echo "would delete $id $key"; deleted=$((deleted + 1)); continue; fi
  if gh cache delete "$id" --repo "${REPO:?}" >/dev/null 2>&1; then deleted=$((deleted + 1)); echo "delete $id $key"
  else failed=$((failed + 1)); echo "::warning::cache-prune.sh: could not delete $id $key"; fi
done < <(decide "$listing" "$REF")
echo "cache-prune.sh: $REF: kept $kept, deleted $deleted, failed $failed"
exit 0

#!/usr/bin/env bash
# Whether a run saves a cache (docs/develop/ci.md, "What is cached"): one rule for the target caches, the registry, the
# models, the Nidhogg tarball and the fuzz corpus.  Prints `save=true|false` and `why=` for $GITHUB_OUTPUT.
#
#   cache-policy.sh              from the environment below
#   cache-policy.sh --self-test  the rule's cases
#
# Environment: EVENT (github.event_name), REF (github.ref), HEAD_REPO (a pull request's head repository, else empty),
# REPO (github.repository), EXACT_HIT (`true`: the cache was restored by its exact key), BUILD_OUTCOME (the step that
# made what is saved).  Saved only when ALL hold: a push or a manual run (never a pull request: its entries are scoped
# to its merge ref, read by no other run, and filled the repository's 10 GB on 2026-11-06), on main, a ci/* branch or
# scratch/drgnx-mac-rounds (the user's macOS workbench), from this repository, the build succeeded, and the exact
# key is not there yet.  bash 3.2-safe.
set -u

decide() {
  local event=${EVENT:-} ref=${REF:-} head=${HEAD_REPO:-} repo=${REPO:-}
  case $event in
    push|workflow_dispatch) ;;
    *) echo "save=false"; echo "why=a $event run never saves"; return ;;
  esac
  case $ref in
    refs/heads/main|refs/heads/ci/*|refs/heads/scratch/drgnx-mac-rounds) ;;
    *) echo "save=false"; echo "why=$ref is not main, ci/* or scratch/drgnx-mac-rounds"; return ;;
  esac
  if [ -n "$head" ] && [ "$head" != "$repo" ]; then echo "save=false"; echo "why=a fork never saves"; return; fi
  if [ "${BUILD_OUTCOME:-}" != success ]; then echo "save=false"; echo "why=the build was ${BUILD_OUTCOME:-not run}, not success"; return; fi
  if [ "${EXACT_HIT:-}" = true ]; then echo "save=false"; echo "why=the exact key is already saved"; return; fi
  echo "save=true"; echo "why=$event on $ref, the build succeeded and the key is new"
}

if [ "${1:-}" = --self-test ]; then
  rc=0
  # expect save ENV...
  expect() {
    local want=$1 got
    shift
    got=$( (EVENT='' REF='' HEAD_REPO='' REPO=o/r EXACT_HIT=false BUILD_OUTCOME=success; for kv in "$@"; do export "${kv?}"; done; decide) | sed -n 's/^save=//p')
    [ "$got" = "$want" ] || { echo "cache-policy.sh self-test FAIL: $* => save=$got, want $want"; rc=1; }
  }
  expect false EVENT=pull_request REF=refs/pull/5/merge HEAD_REPO=o/r
  expect false EVENT=pull_request REF=refs/pull/5/merge HEAD_REPO=fork/r
  expect false EVENT=pull_request REF=refs/heads/main HEAD_REPO=o/r
  expect true EVENT=push REF=refs/heads/main
  expect true EVENT=workflow_dispatch REF=refs/heads/ci/flow
  expect true EVENT=workflow_dispatch REF=refs/heads/ci/flow-probe
  expect true EVENT=push REF=refs/heads/scratch/drgnx-mac-rounds
  expect false EVENT=workflow_dispatch REF=refs/heads/line/x
  expect false EVENT=push REF=refs/heads/scratch/other
  expect false EVENT=schedule REF=refs/heads/main
  expect false EVENT=push REF=refs/heads/main EXACT_HIT=true
  expect false EVENT=push REF=refs/heads/main BUILD_OUTCOME=failure
  expect false EVENT=push REF=refs/heads/main BUILD_OUTCOME=skipped
  expect false EVENT=push REF=refs/heads/main BUILD_OUTCOME=
  expect false EVENT=push REF=refs/heads/main HEAD_REPO=fork/r
  [ "$rc" = 0 ] && echo "cache-policy.sh self-test: ok"
  exit $rc
fi

[ $# -eq 0 ] || { echo "usage: cache-policy.sh | --self-test" >&2; exit 2; }
decide

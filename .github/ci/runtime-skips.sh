#!/usr/bin/env bash
# The runtime workflow's jobs its gate may see skipped, for one run (docs/develop/ci.md, "Gates").  It prints them,
# space-separated, for the `Runtime gate` job's `allow-skipped`; every other job must succeed.
#
#   runtime-skips.sh [TABLE [WORKFLOW]]   in a workflow: EVENT, REF and ONLY below (default: runtime-jobs.txt beside
#                                         this script, ../workflows/runtime.yml)
#   runtime-skips.sh --self-test          the rules against a fixture table and workflow, then the repository's own
#
# Environment: EVENT (github.event_name: a call from ci.yml passes the caller's), REF (github.ref), ONLY (the
# workflow's `only` input: the rt ids a narrowed or path-filtered run asks for; empty: all).
#
# A job may be skipped when one of its skip-when tokens (runtime-jobs.txt) matches this run: `pr` a pull request,
# `cache-run` a push to main (main's push only builds and saves the caches, so every `consumer` has it too),
# `schedule` the daily run, `dispatch-only:ID` any run but a dispatch whose ONLY names ID.  Or when ONLY is not empty,
# names none of the job's ids, and no job that runs needs it (gate-needs.sh reads the `needs:`; a consumer asked for
# alone brings its build).  The job `gate` is never listed.  The table and the workflow must name the same jobs, and
# the tokens must be known: anything else exits 2, so the gate fails.  bash 3.2-safe.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)

skips() {
  local table=$1 wf=$2 needs
  [ -f "$table" ] && [ -f "$wf" ] || { echo "runtime-skips.sh: no $table or $wf" >&2; return 2; }
  needs=$(bash "$HERE/gate-needs.sh" jobs "$wf") || return 2
  printf '%s\n' "$needs" | awk -v ev="${EVENT:-}" -v ref="${REF:-}" -v only=" ${ONLY:-} " '
    BEGIN { gsub(/[[:space:]]+/, " ", only); blank = (only == " ") }
    FNR == NR { split($0, f, "\t"); need[f[1]] = (f[2] == "-" ? "" : f[2]); inwf[f[1]] = 1; next }
    { sub(/#.*/, "") }
    NF == 0 { next }
    {
      id = $1; order[++n] = id; ids[id] = $2; role[id] = $3; intable[id] = 1
      if (role[id] != "build" && role[id] != "consumer" && role[id] != "check") { print "runtime-skips.sh: " id ": role " role[id] > "/dev/stderr"; bad = 1 }
      tok[id] = 0
      for (i = 4; i <= NF; i++) {
        t = $i
        if (t == "pr") { if (ev == "pull_request") tok[id] = 1 }
        else if (t == "cache-run") { if (ev == "push" && ref == "refs/heads/main") tok[id] = 1 }
        else if (t == "schedule") { if (ev == "schedule") tok[id] = 1 }
        else if (t ~ /^dispatch-only:/) { x = t; sub(/^dispatch-only:/, "", x); if (!(ev == "workflow_dispatch" && index(only, " " x " "))) tok[id] = 1 }
        else { print "runtime-skips.sh: " id ": no skip-when token " t > "/dev/stderr"; bad = 1 }
      }
      if (role[id] == "consumer" && ev == "push" && ref == "refs/heads/main") tok[id] = 1
    }
    END {
      for (j in inwf) if (!(j in intable)) { print "runtime-skips.sh: job " j " is not in the table" > "/dev/stderr"; bad = 1 }
      for (k = 1; k <= n; k++) if (!(order[k] in inwf)) { print "runtime-skips.sh: " order[k] " is not a job of the workflow" > "/dev/stderr"; bad = 1 }
      if (bad) exit 2
      for (k = 1; k <= n; k++) {
        j = order[k]; sel = 0
        if (ids[j] == "-" || blank) sel = 1
        else { m = split(ids[j], a, ","); for (i = 1; i <= m; i++) if (index(only, " " a[i] " ")) sel = 1 }
        needed[j] = (sel && !tok[j] && j != "gate")
      }
      do {
        more = 0
        for (k = 1; k <= n; k++) {
          j = order[k]
          if (!needed[j]) continue
          m = split(need[j], a, " ")
          for (i = 1; i <= m; i++) if (!needed[a[i]]) { needed[a[i]] = 1; more = 1 }
        }
      } while (more)
      out = ""
      for (k = 1; k <= n; k++) { j = order[k]; if (j != "gate" && (tok[j] || !needed[j])) out = out (out == "" ? "" : " ") j }
      print out
    }
  ' - "$table"
}

if [ "${1:-}" = --self-test ]; then
  rc=0 d=$(mktemp -d "${TMPDIR:-/tmp}/runtime-skips-test.XXXXXX")
  trap 'rm -r "$d"' EXIT
  # the shape the redesign ends in (x64-build serves the escape legs and agent-containers): only the needs matter here
  cat > "$d/rt.yml" <<'YML'
jobs:
  images:
    runs-on: ubuntu-24.04
  fedora-build:
    needs: images
    runs-on: ubuntu-24.04
  x64-build:
    runs-on: ubuntu-24.04
  escape-host:
    needs: [x64-build]
    runs-on: ubuntu-24.04
  agent-containers:
    needs: [x64-build]
    runs-on: ubuntu-26.04
  msrv:
    runs-on: ubuntu-24.04
  fleet:
    runs-on: ubuntu-24.04
  deny:
    runs-on: ubuntu-24.04
  fuzz-build:
    runs-on: ubuntu-24.04
  fuzz:
    needs: fuzz-build
    runs-on: ubuntu-24.04
  gate:
    needs: [images, fedora-build, x64-build, escape-host, agent-containers, msrv, fleet, deny, fuzz-build, fuzz]
    runs-on: ubuntu-24.04
YML
  cat > "$d/t.txt" <<'TBL'
images            rt-linux       build     schedule
fedora-build      rt-linux       build     schedule
x64-build         rt-escape      build     schedule
escape-host       rt-escape      consumer  schedule
agent-containers  rt-containers  consumer  schedule
msrv              rt-msrv        check     schedule
fleet             rt-fleet       check     dispatch-only:rt-fleet
deny              rt-deny        check
fuzz-build        rt-fuzz        build     pr
fuzz              rt-fuzz        consumer  pr cache-run
gate              -              check
TBL
  # expect "SKIPS" ENV...
  expect() {
    local want=$1 got
    shift
    got=$( (for kv in "$@"; do export "${kv?}"; done; skips "$d/t.txt" "$d/rt.yml") 2>&1 )
    [ "$got" = "$want" ] || { echo "runtime-skips.sh self-test FAIL: $* => '$got', want '$want'"; rc=1; }
  }
  # a consumer asked for alone brings its build: not x64-build, not agent-containers
  expect "images fedora-build escape-host msrv fleet deny fuzz-build fuzz" EVENT=workflow_dispatch REF=refs/heads/ci/flow ONLY=rt-containers
  expect "images fedora-build x64-build escape-host agent-containers fleet fuzz-build fuzz" EVENT=workflow_dispatch REF=refs/heads/ci/flow ONLY="rt-msrv rt-deny"
  expect "fleet fuzz-build fuzz" EVENT=pull_request REF=refs/pull/5/merge ONLY=
  expect "images fedora-build agent-containers msrv fleet deny fuzz-build fuzz" EVENT=pull_request REF=refs/pull/5/merge ONLY="rt-escape"
  # main's push is the cache run: the consumers and the fuzz shards, never a build
  expect "escape-host agent-containers fleet fuzz" EVENT=push REF=refs/heads/main ONLY=
  expect "fleet" EVENT=push REF=refs/heads/ci/flow ONLY=
  expect "images fedora-build x64-build escape-host agent-containers msrv fleet" EVENT=schedule REF=refs/heads/main ONLY=
  expect "images fedora-build x64-build escape-host agent-containers msrv deny fuzz-build fuzz" EVENT=workflow_dispatch REF=refs/heads/ci/flow ONLY=rt-fleet
  # a table and a workflow that disagree, or an unknown token: exit 2
  printf 'stray rt-x check\n' >> "$d/t.txt"
  ( EVENT=push REF=refs/heads/ci/flow ONLY='' skips "$d/t.txt" "$d/rt.yml" >/dev/null 2>&1 ); st=$?
  [ "$st" = 2 ] || { echo "runtime-skips.sh self-test FAIL: a table row with no job => exit $st, want 2"; rc=1; }
  sed -i.bak '/^stray/d; s/^deny              rt-deny        check/deny rt-deny check pull-request/' "$d/t.txt"
  ( EVENT=push REF=refs/heads/ci/flow ONLY='' skips "$d/t.txt" "$d/rt.yml" >/dev/null 2>&1 ); st=$?
  [ "$st" = 2 ] || { echo "runtime-skips.sh self-test FAIL: an unknown token => exit $st, want 2"; rc=1; }
  # the repository's table and workflow: main's push skips no build, a pull request only what the table says
  T="$HERE/runtime-jobs.txt" W="$HERE/../workflows/runtime.yml"
  if [ -f "$T" ] && [ -f "$W" ]; then
    out=$(EVENT=push REF=refs/heads/main ONLY='' skips "$T" "$W") || { echo "runtime-skips.sh self-test FAIL: $T: exit $?"; rc=1; }
    for b in $(sed 's/#.*//' "$T" | awk '$3 == "build" { print $1 }'); do
      case " $out " in *" $b "*) echo "runtime-skips.sh self-test FAIL: main's cache run may skip the build $b"; rc=1 ;; esac
    done
    out=$(EVENT=push REF=refs/heads/ci/flow ONLY='' skips "$T" "$W")
    [ "$out" = fleet ] || { echo "runtime-skips.sh self-test FAIL: a full ci run may skip '$out', want 'fleet'"; rc=1; }
  else
    echo "runtime-skips.sh self-test FAIL: no $T or $W"; rc=1
  fi
  [ "$rc" = 0 ] && echo "runtime-skips.sh self-test: ok"
  exit $rc
fi

[ $# -le 2 ] || { echo "usage: runtime-skips.sh [TABLE [WORKFLOW]] | --self-test" >&2; exit 2; }
skips "${1:-$HERE/runtime-jobs.txt}" "${2:-$HERE/../workflows/runtime.yml}"

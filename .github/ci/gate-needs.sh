#!/usr/bin/env bash
# The runtime workflow's jobs against its job table (runtime-jobs.txt beside this script; docs/develop/ci.md, "Gates").
#
#   gate-needs.sh jobs WORKFLOW           each job of WORKFLOW: `id<TAB>needs (space-separated, - for none)<TAB>if (- for none)`
#   gate-needs.sh --check WORKFLOW TABLE  fails unless the two agree (below)
#   gate-needs.sh --self-test             the rules against fixtures of its own
#
# --check fails unless: the workflow's job ids are the table's; the job `gate` needs every other job; every
# `consumer` needs a `build` job of the table and its `if:` begins with `${{ !cancelled()` (so it runs, and fails,
# when its build failed: a consumer never hides as skipped); each job's `if:` names exactly the table's ids (`' rt-x '`,
# none for `-`); and the table's roles and skip-when tokens are ones runtime-skips.sh knows, no build skipped on the
# cache run.  The workflow is read line by line: jobs at two spaces under `jobs:`, `needs:` and `if:` at four, `needs`
# a word, a `[a, b]` list or a `- a` list below it, `if` on one line.
# The table: `<job id> <rt ids, comma-separated, or -> <build|consumer|check> <skip-when tokens: pr cache-run schedule
# dispatch-only:ID>`, `#` comments.  bash 3.2-safe.  Exit 0 agree, 1 disagree or a failed self-test, 2 usage.
set -u

usage() { echo "usage: gate-needs.sh jobs WORKFLOW | --check WORKFLOW TABLE | --self-test" >&2; exit 2; }

jobs_of() {
  [ -f "$1" ] || { echo "gate-needs.sh: no workflow $1" >&2; return 2; }
  awk '
    function flush() {
      if (id != "") {
        gsub(/[[:space:]]+/, " ", needs); sub(/^ /, "", needs); sub(/ $/, "", needs)
        printf "%s\t%s\t%s\n", id, (needs == "" ? "-" : needs), (cond == "" ? "-" : cond)
      }
      id = ""; needs = ""; cond = ""; inneeds = 0
    }
    /^jobs:[[:space:]]*$/ { injobs = 1; next }
    injobs && /^[^[:space:]#]/ { flush(); injobs = 0 }
    !injobs { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); id = $1; sub(/:$/, "", id); next }
    id == "" { next }
    inneeds && /^      - / { v = $0; sub(/^      - /, "", v); sub(/[[:space:]]+#.*$/, "", v); needs = needs " " v; next }
    /^    [A-Za-z_-]+:/ { inneeds = 0 }
    /^    needs:/ { v = $0; sub(/^    needs:[[:space:]]*/, "", v); sub(/[[:space:]]+#.*$/, "", v)
                    if (v == "") inneeds = 1; else { gsub(/[][,]/, " ", v); needs = v }
                    next }
    /^    if:/ { v = $0; sub(/^    if:[[:space:]]*/, "", v); cond = v; next }
    END { flush() }
  ' "$1"
}

# the table's rows without comments: `id ids role tokens…`
rows_of() { sed 's/#.*//' "$1" | awk 'NF { $1 = $1; print }'; }

has() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

check() {
  local wf=$1 table=$2 jobs rows ids wids tids id need cond role tok fail="" n gate_needs want got builds
  [ -f "$table" ] || { echo "gate-needs.sh: no table $table" >&2; return 2; }
  jobs=$(jobs_of "$wf") || return 2
  rows=$(rows_of "$table")
  wids=$(printf '%s\n' "$jobs" | cut -f1 | tr '\n' ' ')
  tids=$(printf '%s\n' "$rows" | cut -d' ' -f1 | tr '\n' ' ')
  for id in $wids; do has "$id" "$tids" || fail="$fail; job $id is not in $table"; done
  for id in $tids; do has "$id" "$wids" || fail="$fail; $table's $id is not a job of $wf"; done
  gate_needs=$(printf '%s\n' "$jobs" | awk -F'\t' '$1 == "gate" { print $2 }')
  if [ -z "$gate_needs" ]; then fail="$fail; $wf has no job gate"
  else
    for id in $wids; do [ "$id" = gate ] || has "$id" "$gate_needs" || fail="$fail; gate does not need $id"; done
  fi
  builds=$(printf '%s\n' "$rows" | awk '$3 == "build" { print $1 }' | tr '\n' ' ')
  while read -r id ids role tok; do
    [ -n "$id" ] || continue
    case $role in build|consumer|check) ;; *) fail="$fail; $id: role $role is not build, consumer or check" ;; esac
    for t in $tok; do
      case $t in pr|cache-run|schedule|dispatch-only:rt-*) ;; *) fail="$fail; $id: no skip-when token $t" ;; esac
      [ "$role:$t" != build:cache-run ] || fail="$fail; $id: a build job is never skipped on the cache run"
    done
    has "$id" "$wids" || continue
    need=$(printf '%s\n' "$jobs" | awk -F'\t' -v j="$id" '$1 == j { print $2 }')
    cond=$(printf '%s\n' "$jobs" | awk -F'\t' -v j="$id" '$1 == j { print $3 }')
    if [ "$role" = consumer ]; then
      n=0; for t in $need; do ! has "$t" "$builds" || n=1; done
      [ "$n" = 1 ] || fail="$fail; consumer $id needs no build job (needs: $need)"
      case $cond in '${{ !cancelled()'*) ;; *) fail="$fail; consumer $id's if: does not begin with \${{ !cancelled() ($cond)" ;; esac
    fi
    want=$(printf '%s\n' "$ids" | tr ',' '\n' | grep -v '^-$' | LC_ALL=C sort -u | tr '\n' ' ')
    got=$(printf '%s\n' "$cond" | grep -oE "' rt-[a-z0-9-]+ '" | tr -d "' " | LC_ALL=C sort -u | tr '\n' ' ')
    [ "$want" = "$got" ] || fail="$fail; $id's if: names ${got:-no id}, the table ${want:-none}"
  done <<<"$rows"
  if [ -n "$fail" ]; then printf 'gate-needs.sh: %s\n' "${fail#; }" | sed 's/; /\ngate-needs.sh: /g'; return 1; fi
  echo "gate-needs.sh: $wf and $table agree ($(printf '%s\n' "$rows" | wc -l | tr -d ' ') jobs)"
}

if [ "${1:-}" = --self-test ]; then
  rc=0 d=$(mktemp -d "${TMPDIR:-/tmp}/gate-needs-test.XXXXXX")
  trap 'rm -r "$d"' EXIT
  cat > "$d/rt.yml" <<'YML'
name: Runtime
on: workflow_call
jobs:
  x64-build:
    name: build (ubuntu-24.04)
    if: ${{ github.event_name != 'schedule' && (!inputs.only || contains(format(' {0} ', inputs.only), ' rt-escape ')) }}
    runs-on: ubuntu-24.04
    steps:
      - if: ${{ always() }}
        run: true
  escape-host:
    name: escape
    needs: x64-build
    if: ${{ !cancelled() && (!inputs.only || contains(format(' {0} ', inputs.only), ' rt-escape ')) }}
    runs-on: ubuntu-24.04
    steps:
      - run: true
  deny:
    if: ${{ !inputs.only || contains(format(' {0} ', inputs.only), ' rt-deny ') }}
    runs-on: ubuntu-24.04
    steps:
      - run: true
  gate:
    name: Runtime gate
    if: always()
    needs:
      - x64-build   # the build
      - escape-host
      - deny
    runs-on: ubuntu-24.04
    steps:
      - run: true
YML
  printf '%s\n' '# a table' 'x64-build    rt-escape  build     schedule' 'escape-host  rt-escape  consumer  cache-run   # rows' \
    'deny         rt-deny    check' 'gate         -          check' > "$d/t.txt"
  # expect 0|1 WORKFLOW TABLE what
  expect() {
    local out st
    out=$(check "$2" "$3" 2>&1); st=$?
    [ "$st" = "$1" ] || { echo "gate-needs.sh self-test FAIL: $4: exit $st, want $1: $out"; rc=1; }
  }
  [ "$(jobs_of "$d/rt.yml" | awk -F'\t' '$1 == "gate" { print $2 }')" = "x64-build escape-host deny" ] ||
    { echo "gate-needs.sh self-test FAIL: the gate's needs list: $(jobs_of "$d/rt.yml")"; rc=1; }
  expect 0 "$d/rt.yml" "$d/t.txt" "the table and the workflow agree"
  sed '/      - deny/d' "$d/rt.yml" > "$d/a.yml"
  expect 1 "$d/a.yml" "$d/t.txt" "a job missing from the gate's needs"
  sed "s/if: \${{ !cancelled() && (!inputs.only/if: \${{ success() \&\& (!inputs.only/" "$d/rt.yml" > "$d/b.yml"
  grep -q 'success() &&' "$d/b.yml" || { echo "gate-needs.sh self-test FAIL: the success() fixture did not apply"; rc=1; }
  expect 1 "$d/b.yml" "$d/t.txt" "a consumer's if: success()"
  grep -v '^deny' "$d/t.txt" > "$d/c.txt"
  expect 1 "$d/rt.yml" "$d/c.txt" "a job missing from the table"
  sed '/^    needs: x64-build$/d' "$d/rt.yml" > "$d/e.yml"
  expect 1 "$d/e.yml" "$d/t.txt" "a consumer that needs no build"
  sed 's/^deny         rt-deny /deny         rt-msrv /' "$d/t.txt" > "$d/f.txt"
  expect 1 "$d/rt.yml" "$d/f.txt" "an if: naming other ids than the table"
  sed 's/^x64-build    rt-escape  build     schedule/x64-build    rt-escape  build     cache-run/' "$d/t.txt" > "$d/g.txt"
  expect 1 "$d/rt.yml" "$d/g.txt" "a build skipped on the cache run"
  [ "$rc" = 0 ] && echo "gate-needs.sh self-test: ok"
  exit $rc
fi

case ${1:-} in
  jobs) [ $# -eq 2 ] || usage; jobs_of "$2" ;;
  --check) [ $# -eq 3 ] || usage; check "$2" "$3" ;;
  *) usage ;;
esac

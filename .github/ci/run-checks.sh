#!/usr/bin/env bash
# The checks a CI run must pass, read from the run itself (its jobs, their logs, its artifacts) through the GitHub
# API (docs/develop/ci.md, "Checking a run").  One line per check, `check N: PASS|FAIL <why>`; exit 0 when every check
# it ran passed, 1 when one failed, 2 on a usage error.
#
#   run-checks.sh runs SHA                      1: at most one pull_request and one push run of CI for SHA, the push on main
#   run-checks.sh compiles RUN                  2: per job, the hub's and all `Compiling ` lines against compile-budget.txt
#   run-checks.sh cache RUN                     3: every build job restored its target cache within its toolchain, and
#                                                  compiled fewer than 5 % of the third-party packages of its target
#   run-checks.sh budget [--before LISTING]     4: the repository's caches stay under 10 GiB, and main's keys in LISTING
#                                                  (a saved `gh api …/actions/caches --paginate`) are all still there
#   run-checks.sh wall RUN --warm|--cold        5: the run's creation to its CI gate's end, at most 25 or 60 minutes
#   run-checks.sh seeded RUN [--gate-fails] --failed JOB...
#                                               6: the CI gate failed (or passed, without --gate-fails), and each job whose
#                                                  name holds JOB (any case) failed, none skipped
#   run-checks.sh coverage RUN BASE_RUN         7: the same test, row and escape-report counts as BASE_RUN
#   run-checks.sh macos RUN...                  8: at most 6 macOS jobs over the runs (one push's), at most 4 at once
#   run-checks.sh env RUN                       9: the Fedora jobs run the Prebuilt image's digest, and every `rustc -V`
#                                                  (or toolchain.txt) line is test/container/rust-version's
#   run-checks.sh shards RUN [--base BASE_RUN]  10: each Fedora test consumer's `shard-stats:` line (its test step's
#                                                  seconds and peak memory; a warning above 12 GiB of the runner's 16)
#   run-checks.sh all RUN [--base BASE_RUN] [--warm|--cold]   every check that applies to one run
#   run-checks.sh --self-test                   the checks against the fixtures in run-checks/ beside this script
#
# compile-budget.txt rows: `<job-name glob> <max hub compiles> <max Compiling lines|any>`, the first match wins; a job
# no row matches fails check 2.  A row with `any` is a build job (check 3 reads its cache); `0 0` a consumer, which
# compiles nothing.  The build jobs print `cache-primary-key: <key>` (the key they would save); a restored key is
# `Cache restored from key: cargo-…` (actions/cache), and both carry the toolchain as `-rustc-<version>-`.
#
# Environment: CHECKS_GH replaces gh (the self-test's stand-in); CHECKS_REPO (default GITHUB_REPOSITORY, else
# Black-Dragon-Foundation/drgnx); CHECKS_CACHE, a directory that keeps the fetched jobs and logs between calls;
# CHECKS_METADATA, a saved `cargo metadata --format-version 1` used for every target instead of running cargo;
# CHECKS_RUST_VERSION, the file with the pinned version.  bash 3.2-safe; needs jq.
set -u
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
GH=${CHECKS_GH:-gh}
REPO=${CHECKS_REPO:-${GITHUB_REPOSITORY:-Black-Dragon-Foundation/drgnx}}
BUDGET=${CHECKS_BUDGET:-$HERE/compile-budget.txt}
RUST_VERSION_FILE=${CHECKS_RUST_VERSION:-$ROOT/test/container/rust-version}
GIB=1073741824
COMPILING='Compiling [A-Za-z0-9_-]+ v[0-9]'
RC=0
# the Fedora test consumers that report shard-stats (check 10)
is_shard_job() {
  case $1 in *"/ tests "[0-9]/[0-9]*"(Fedora"*|*"/ live debug adapters"*|*"/ rows"*"(Fedora"*) return 0 ;; esac
  return 1
}

usage() { echo "usage: run-checks.sh runs|compiles|cache|budget|wall|seeded|coverage|macos|env|shards|all ARGS | --self-test" >&2; exit 2; }

if [ -n "${CHECKS_CACHE:-}" ]; then WORK=$CHECKS_CACHE; mkdir -p "$WORK"
else WORK=$(mktemp -d "${TMPDIR:-/tmp}/run-checks.XXXXXX"); trap 'rm -r "$WORK"' EXIT; fi

say() { echo "check $1: $2 $3"; [ "$2" != FAIL ] || RC=1; }
# words of a "; "-joined list, without the leading "; "
why() { echo "${1#; }"; }
gib() { awk -v b="$1" -v g="$GIB" 'BEGIN { printf "%.2f GiB", b / g }'; }

# --- what a run is: its jobs (a JSON array), its record, a job's log, fetched once ----------------------------------
jobs_file() {
  local f="$WORK/$1.jobs.json"
  if [ ! -s "$f" ]; then
    "$GH" api --paginate "repos/$REPO/actions/runs/$1/jobs?per_page=100" 2>/dev/null | jq -s '[.[].jobs[]]' > "$f.part" &&
      mv "$f.part" "$f" || { rm -f "$f.part"; return 1; }
  fi
  echo "$f"
}
run_file() {
  local f="$WORK/$1.run.json"
  if [ ! -s "$f" ]; then
    "$GH" api "repos/$REPO/actions/runs/$1" 2>/dev/null > "$f.part" && mv "$f.part" "$f" || { rm -f "$f.part"; return 1; }
  fi
  echo "$f"
}
log_file() {
  local f="$WORK/log-$1.txt"
  if [ ! -s "$f" ]; then
    "$GH" api "repos/$REPO/actions/jobs/$1/logs" 2>/dev/null > "$f.part" && [ -s "$f.part" ] && mv "$f.part" "$f" ||
      { rm -f "$f.part"; return 1; }
  fi
  echo "$f"
}
# id, conclusion (or status), labels, name: one job a line, tab-separated
jobs_tsv() { jq -r '.[] | [.id, (.conclusion // .status), ((.labels // []) | join(",") | if . == "" then "-" else . end), .name] | @tsv' "$1"; }
is_macos() { case $1 in *xcode*|*macos*) return 0 ;; esac; return 1; }

# the budget row of a job name: "HUB LINES", or nothing (status 1)
budget_of() {
  local line l glob hub lines
  while IFS= read -r line || [ -n "$line" ]; do
    l=$(printf '%s\n' "${line%%#*}" | tr '\t' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')
    [ -n "$l" ] || continue
    lines=${l##* }; l=${l% *}; hub=${l##* }; glob=${l% *}
    # shellcheck disable=SC2053  # the row is a glob on purpose
    if [[ $1 == $glob ]]; then echo "$hub $lines"; return 0; fi
  done < "$BUDGET"
  return 1
}

# the part of a cache key up to its toolchain: everything through `-rustc-<version>-`
toolchain_prefix() {
  local rest
  case $1 in *-rustc-*) rest=${1#*-rustc-}; echo "${1%%-rustc-*}-rustc-${rest%%-*}-" ;; *) echo "$1" ;; esac
}

# --- 1: one run per push ------------------------------------------------------------------------------------------
check_runs() {
  local full out pr push off
  [ $# -eq 1 ] || usage
  full=$("$GH" api "repos/$REPO/commits/$1" 2>/dev/null | jq -r '.sha // empty') && [ -n "$full" ] ||
    { say 1 FAIL "no commit $1"; return; }
  out=$("$GH" api --paginate "repos/$REPO/actions/runs?head_sha=$full&per_page=100" 2>/dev/null |
          jq -rs '[.[].workflow_runs[] | select(.name == "CI")] | .[] | "\(.id) \(.event) \(.head_branch)"') ||
    { say 1 FAIL "the runs of ${full:0:12} could not be listed"; return; }
  pr=$(printf '%s\n' "$out" | grep -c ' pull_request ')
  push=$(printf '%s\n' "$out" | grep -c ' push ')
  off=$(printf '%s\n' "$out" | awk '$2 == "push" && $3 != "main"' | tr '\n' ';' | sed 's/;$//; s/;/; /g')
  if [ "$pr" -le 1 ] && [ "$push" -le 1 ] && [ -z "$off" ]; then
    say 1 PASS "${full:0:12}: $pr pull_request, $push push run(s) of CI"
  else
    say 1 FAIL "${full:0:12}: $pr pull_request and $push push runs of CI${off:+ (a push off main: $off)}: $(printf '%s\n' "$out" | grep -E ' (push|pull_request) ' | tr '\n' ';' | sed 's/;$//; s/;/, /g')"
  fi
}

# --- 2: one compile per key ---------------------------------------------------------------------------------------
check_compiles() {
  local jf id concl labels name log row mh ml hub all fail="" n=0 total=0
  [ $# -eq 1 ] || usage
  jf=$(jobs_file "$1") || { say 2 FAIL "the jobs of run $1 could not be read"; return; }
  while IFS=$'\t' read -r id concl labels name; do
    [ "$concl" != skipped ] || continue
    n=$((n + 1))
    row=$(budget_of "$name") || { fail="$fail; $name: no row in compile-budget.txt"; continue; }
    log=$(log_file "$id") || { fail="$fail; $name: no log"; continue; }
    hub=$(grep -c 'Compiling ratatoskr v' "$log")
    all=$(grep -cE "$COMPILING" "$log")
    total=$((total + hub)) mh=${row% *} ml=${row#* }
    [ "$hub" -le "$mh" ] || fail="$fail; $name: the hub ×$hub (budget $mh)"
    [ "$ml" = any ] || [ "$all" -le "$ml" ] || fail="$fail; $name: $all Compiling lines (budget $ml)"
  done < <(jobs_tsv "$jf")
  if [ -z "$fail" ]; then say 2 PASS "run $1: $n jobs within compile-budget.txt, the hub ×$total in all"
  else say 2 FAIL "run $1: $(why "$fail")"; fi
}

# the target of a job's build, for cargo metadata
triple_of() {
  case $2 in *Android*) echo aarch64-linux-android; return ;; esac
  case $1 in *xcode*|*macos*) echo aarch64-apple-darwin ;; *arm*) echo aarch64-unknown-linux-gnu ;; *) echo x86_64-unknown-linux-gnu ;; esac
}
# the third-party package names of a target, one a line (sorted)
third_party() {
  local f="$WORK/third-party-$1.txt" m="$WORK/meta-$1.json"
  if [ ! -s "$f" ]; then
    if [ -n "${CHECKS_METADATA:-}" ]; then cp "$CHECKS_METADATA" "$m"
    else (cd "$ROOT" && cargo metadata --format-version 1 --locked --filter-platform "$1") > "$m" 2>/dev/null || return 1
    fi
    jq -r '.workspace_members as $ws | ([.packages[] | {key: .id, value: .name}] | from_entries) as $n
           | [.resolve.nodes[].id | select(IN($ws[]) | not) | $n[.]] | unique[]' "$m" | LC_ALL=C sort -u > "$f" || return 1
  fi
  echo "$f"
}

# --- 3: cache hit -------------------------------------------------------------------------------------------------
check_cache() {
  local jf id concl labels name log row restored primary compiled tp c t fail="" n=0 report=""
  [ $# -eq 1 ] || usage
  jf=$(jobs_file "$1") || { say 3 FAIL "the jobs of run $1 could not be read"; return; }
  while IFS=$'\t' read -r id concl labels name; do
    [ "$concl" != skipped ] || continue
    row=$(budget_of "$name") || continue          # check 2 reports it
    [ "${row#* }" = any ] || continue
    log=$(log_file "$id") || { fail="$fail; $name: no log"; continue; }
    restored=$(grep -oE 'Cache restored from key: cargo-[^ ]+' "$log" | grep -v ': cargo-registry-' | head -1)
    restored=${restored#Cache restored from key: }
    primary=$(grep -oE 'cache-primary-key: cargo-[^ ]+' "$log" | head -1)
    primary=${primary#cache-primary-key: }
    if [ -z "$primary" ]; then
      primary=$(grep -oE 'Cache not found for input keys: cargo-[^ ,]+' "$log" | grep -v ': cargo-registry-' | head -1)
      primary=${primary#Cache not found for input keys: }
    fi
    compiled=$(grep -cE "$COMPILING" "$log")
    [ -n "$restored$primary" ] || [ "$compiled" -gt 0 ] || continue   # builds nothing: not a build job here
    n=$((n + 1))
    if [ -z "$restored" ]; then
      if [ -n "$primary" ]; then fail="$fail; $name: Cache not found ($primary)"; else fail="$fail; $name: restores no target cache"; fi
      continue
    fi
    [ -n "$primary" ] || { fail="$fail; $name: no cache-primary-key line"; continue; }
    if [ "$(toolchain_prefix "$restored")" != "$(toolchain_prefix "$primary")" ]; then
      fail="$fail; $name: restored $restored, outside $(toolchain_prefix "$primary")"; continue
    fi
    tp=$(third_party "$(triple_of "$labels" "$name")") || { fail="$fail; $name: no cargo metadata (set CHECKS_METADATA)"; continue; }
    t=$(wc -l < "$tp" | tr -d ' ')
    c=$(grep -oE 'Compiling [A-Za-z0-9_-]+ v' "$log" | awk '{ print $2 }' | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$tp" | wc -l | tr -d ' ')
    if [ "$t" -eq 0 ] || [ $((c * 100)) -ge $((t * 5)) ]; then
      fail="$fail; $name: $c of $t third-party packages compiled (5 % allowed)"
    else
      report="$report; $name: $c of $t third-party compiled, from ${restored:0:60}…"
    fi
  done < <(jobs_tsv "$jf")
  if [ -n "$fail" ]; then say 3 FAIL "run $1: $(why "$fail")"
  elif [ "$n" -eq 0 ]; then say 3 PASS "run $1: no build job ran"
  else say 3 PASS "run $1: $(why "$report")"; fi
}

# --- 4: cache budget ----------------------------------------------------------------------------------------------
check_budget() {
  local before="" usage gone now
  case ${1:-} in --before) [ $# -eq 2 ] || usage; before=$2 ;; '') ;; *) usage ;; esac
  usage=$("$GH" api "repos/$REPO/actions/cache/usage" 2>/dev/null | jq -r '.active_caches_size_in_bytes // empty') &&
    [ -n "$usage" ] || { say 4 FAIL "the cache usage could not be read"; return; }
  if [ "$usage" -ge $((10 * GIB)) ]; then say 4 FAIL "the caches hold $(gib "$usage") of 10 GiB"; return; fi
  if [ -n "$before" ]; then
    now=$("$GH" api --paginate "repos/$REPO/actions/caches?per_page=100" 2>/dev/null | jq -r '.actions_caches[].key') ||
      { say 4 FAIL "the cache list could not be read"; return; }
    gone=$(jq -r '.actions_caches[]? | select(.ref == "refs/heads/main") | .key' "$before" | LC_ALL=C sort -u |
             LC_ALL=C comm -23 - <(printf '%s\n' "$now" | LC_ALL=C sort -u) | tr '\n' ' ')
    [ -z "$gone" ] || { say 4 FAIL "$(gib "$usage") of 10 GiB, but main's entries are gone: $gone"; return; }
  fi
  say 4 PASS "the caches hold $(gib "$usage") of 10 GiB${before:+, every main entry of the listing still there}"
}

# --- 5: wall time -------------------------------------------------------------------------------------------------
check_wall() {
  local jf rf max mins
  [ $# -eq 2 ] || usage
  case $2 in --warm) max=25 ;; --cold) max=60 ;; *) usage ;; esac
  jf=$(jobs_file "$1") && rf=$(run_file "$1") || { say 5 FAIL "run $1 could not be read"; return; }
  mins=$(jq -r --slurpfile run "$rf" '[.[] | select(.name | startswith("CI gate")) | .completed_at | select(. != null)] | first
           | if . == null then empty else (((. | fromdateiso8601) - ($run[0].created_at | fromdateiso8601)) / 60 | floor) end' "$jf")
  [ -n "$mins" ] || { say 5 FAIL "run $1 has no finished CI gate"; return; }
  if [ "$mins" -le "$max" ]; then say 5 PASS "run $1: $mins min to the gate (${2#--} budget $max)"
  else say 5 FAIL "run $1: $mins min to the gate (${2#--} budget $max)"; fi
}

# --- 6: no hidden failures ----------------------------------------------------------------------------------------
check_seeded() {
  local run=$1 jf want=success gate pats="" p got fail=""
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --gate-fails) want=failure ;;
      --failed) ;;
      *) pats="$pats$1"$'\n' ;;
    esac
    shift
  done
  [ -n "$pats" ] || usage
  jf=$(jobs_file "$run") || { say 6 FAIL "the jobs of run $run could not be read"; return; }
  gate=$(jq -r '[.[] | select(.name | startswith("CI gate")) | (.conclusion // .status)] | first // "missing"' "$jf")
  [ "$gate" = "$want" ] || fail="$fail; CI gate: $gate, not $want"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    got=$(jq -r --arg p "$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')" \
            '.[] | select(.name | ascii_downcase | contains($p)) | "\(.conclusion // .status)\t\(.name)"' "$jf")
    [ -n "$got" ] || { fail="$fail; no job named like $p"; continue; }
    while IFS=$'\t' read -r concl name; do
      [ "$concl" = failure ] || fail="$fail; $name: $concl, not failure"
    done <<<"$got"
  done <<<"$pats"
  if [ -z "$fail" ]; then say 6 PASS "run $run: CI gate $gate; $(printf '%s' "$pats" | tr '\n' ' ')failed"
  else say 6 FAIL "run $run: $(why "$fail")"; fi
}

# --- 7: same coverage ---------------------------------------------------------------------------------------------
# a run's counts, one "key value" a line, sorted: nextest's tests per platform, the macOS runner's Running lines,
# domr's rows (total and skipped) per platform, and each escape report's rows, statuses and skip reasons
profile() {
  local jf id concl labels name log plat d f
  jf=$(jobs_file "$1") || return 1
  {
    while IFS=$'\t' read -r id concl labels name; do
      [ "$concl" != skipped ] || continue
      log=$(log_file "$id") || continue
      plat=linux; ! is_macos "$labels" || plat=macos
      grep -oE 'Starting [0-9]+ tests? across [0-9]+ binar' "$log" | awk -v p="$plat" '{ print "nextest-tests-" p, $2 }'
      [ "$plat" != macos ] || grep -cE 'Z {5}Running ' "$log" | awk '$1 > 0 { print "macos-running", $1 }'
      grep -oE 'Z [0-9]+ passed, [0-9]+ (skipped|failed), [0-9]+ (skipped|failed)' "$log" |
        awk -v p="$plat" '{ t = $2 + $4 + $6; s = ($5 ~ /skipped/) ? $4 : $6; print "rows-" p, t; print "rows-skipped-" p, s }'
    done < <(jobs_tsv "$jf")
  } | awk '{ a[$1] += $2 } END { for (k in a) print k, a[k] }'
  d="$WORK/escape-$1"
  if [ ! -d "$d" ]; then
    mkdir -p "$d.part" && "$GH" run download "$1" -R "$REPO" -p 'escape-report-*' -D "$d.part" >/dev/null 2>&1
    mv "$d.part" "$d"
  fi
  for f in "$d"/*/*.json; do
    [ -f "$f" ] || continue
    jq -r --arg a "$(basename "$(dirname "$f")")" '
      "escape \($a) rows \(length)",
      (group_by(.status)[] | "escape \($a) \(.[0].status) \(length)"),
      (map(select(.status == "skip")) | group_by(.reason)[] | "escape \($a) reason:\(.[0].reason | gsub(" "; "_")) \(length)")' "$f"
  done
}
check_coverage() {
  local a b diffs
  [ $# -eq 2 ] || usage
  a=$(profile "$2" | LC_ALL=C sort) && b=$(profile "$1" | LC_ALL=C sort) || { say 7 FAIL "runs $1 and $2 could not be read"; return; }
  [ -n "$a" ] || { say 7 FAIL "base run $2 shows no tests, rows or reports"; return; }
  diffs=$(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | grep -E '^[<>]' | sed 's/^</base:/; s/^>/run:/' | tr '\n' ';' | sed 's/;$//; s/;/; /g')
  if [ -z "$diffs" ]; then say 7 PASS "run $1 = base $2: $(printf '%s\n' "$b" | grep -v '^escape' | tr '\n' ';' | sed 's/;$//; s/;/, /g'); $(printf '%s\n' "$b" | grep -c ' rows ') escape reports"
  else say 7 FAIL "run $1 against base $2: $diffs"; fi
}

# --- 8: macOS slots -----------------------------------------------------------------------------------------------
check_macos() {
  local files="" r jf out n peak
  [ $# -ge 1 ] || usage
  for r in "$@"; do jf=$(jobs_file "$r") || { say 8 FAIL "the jobs of run $r could not be read"; return; }; files="$files $jf"; done
  # shellcheck disable=SC2086  # the files, split on purpose
  out=$(jq -s -r 'add | [.[] | select((.labels // []) | any(test("xcode|macos"))) | select(.conclusion != "skipped" and .started_at != null)]
          | (length), ([.[] | [(.started_at | fromdateiso8601), 1], [((.completed_at // (now | todate)) | fromdateiso8601), -1]]
                       | sort_by(.[0], .[1]) | reduce .[] as $e ({c: 0, m: 0}; .c += $e[1] | .m = ([.m, .c] | max)) | .m)' $files)
  n=$(printf '%s\n' "$out" | sed -n 1p); peak=$(printf '%s\n' "$out" | sed -n 2p)
  if [ "$n" -le 6 ] && [ "$peak" -le 4 ]; then say 8 PASS "runs $*: $n macOS jobs, at most $peak at once"
  else say 8 FAIL "runs $*: $n macOS jobs (6 allowed), at most $peak at once (4 allowed)"; fi
}

# --- 9: same environment ------------------------------------------------------------------------------------------
check_env() {
  local jf want id concl labels name log digest="" vers compiled fail="" n=0 fedora=0
  [ $# -eq 1 ] || usage
  want=$(tr -d '[:space:]' < "$RUST_VERSION_FILE") || { say 9 FAIL "no $RUST_VERSION_FILE"; return; }
  jf=$(jobs_file "$1") || { say 9 FAIL "the jobs of run $1 could not be read"; return; }
  id=$(jq -r '[.[] | select((.name | contains("Prebuilt image")) and .conclusion != "skipped") | .id] | first // empty' "$jf")
  if [ -n "$id" ] && log=$(log_file "$id"); then
    digest=$(grep -oE 'rust=[^ ]+@sha256:[0-9a-f]{64}' "$log" | head -1); digest=${digest#rust=}
  fi
  while IFS=$'\t' read -r id concl labels name; do
    [ "$concl" != skipped ] || continue
    log=$(log_file "$id") || { fail="$fail; $name: no log"; continue; }
    case $name in
      *"Prebuilt image"*) ;;
      *Fedora*) fedora=$((fedora + 1))
        if [ -z "$digest" ]; then fail="$fail; $name: no Prebuilt image digest to compare"
        elif ! grep -E 'docker.* pull ' "$log" | grep -qF "$digest"; then fail="$fail; $name: its container is not $digest"; fi ;;
    esac
    case $name in *MSRV*|*fuzz*) continue ;; esac   # their own toolchains: 1.95, the pinned nightly
    vers=$(grep -oE 'Z (toolchain\.txt: )?rustc [0-9]+\.[0-9]+\.[0-9]+[^ ]*' "$log" | awk '{ print $NF }' | sort -u | tr '\n' ' ')
    compiled=$(grep -cE "$COMPILING" "$log")
    if [ -z "$vers" ]; then [ "$compiled" -eq 0 ] || fail="$fail; $name: compiles, but logs no rustc -V"; continue; fi
    n=$((n + 1))
    [ "$vers" = "$want " ] || fail="$fail; $name: rustc ${vers% }, not $want"
  done < <(jobs_tsv "$jf")
  if [ -z "$fail" ]; then say 9 PASS "run $1: $n jobs on rustc $want, $fedora Fedora jobs on ${digest:-no image}"
  else say 9 FAIL "run $1: $(why "$fail")"; fi
}

# --- 10: the Fedora test consumers' time and memory ---------------------------------------------------------------
check_shards() {
  local run=$1 base="" jf id concl labels name log line secs peak fail="" report="" old=""
  shift
  case ${1:-} in --base) [ $# -eq 2 ] || usage; base=$2 ;; '') ;; *) usage ;; esac
  jf=$(jobs_file "$run") || { say 10 FAIL "the jobs of run $run could not be read"; return; }
  while IFS=$'\t' read -r id concl labels name; do
    [ "$concl" != skipped ] && is_shard_job "$name" || continue
    log=$(log_file "$id") || { fail="$fail; $name: no log"; continue; }
    line=$(grep -oE 'shard-stats: .*' "$log" | tail -1)
    secs=$(printf '%s\n' "$line" | sed -n 's/.*step_seconds=\([0-9]*\).*/\1/p')
    peak=$(printf '%s\n' "$line" | sed -n 's/.*peak_bytes=\([0-9]*\).*/\1/p')
    if [ -z "$secs" ] || [ -z "$peak" ]; then fail="$fail; $name: no shard-stats: line"; continue; fi
    [ "$peak" -le $((12 * GIB)) ] || echo "::warning::$name peaked at $(gib "$peak") (the runner has 16 GB)"
    report="$report; $name: ${secs} s, $(gib "$peak")"
  done < <(jobs_tsv "$jf")
  if [ -n "$base" ] && jf=$(jobs_file "$base"); then
    old=$(jq -r '[.[] | select(.name | contains("fmt, clippy, tests, conformance, perf (Fedora 45)")) | select(.completed_at != null)
                  | (((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) / 60 | floor)] | first // empty' "$jf")
  fi
  old=${old:+; the old linux job on $base: $old min}
  if [ -n "$fail" ]; then say 10 FAIL "run $run: $(why "$fail")$old"
  elif [ -z "$report" ]; then say 10 PASS "run $run: no Fedora test consumer ran$old"
  else say 10 PASS "run $run: $(why "$report")$old"; fi
}

check_all() {
  local run=$1 base="" mode="" rf sha
  shift
  while [ $# -gt 0 ]; do
    case $1 in --base) [ $# -ge 2 ] || usage; base=$2; shift ;; --warm|--cold) mode=$1 ;; *) usage ;; esac
    shift
  done
  rf=$(run_file "$run") || { say 0 FAIL "run $run could not be read"; return; }
  sha=$(jq -r .head_sha "$rf")
  check_runs "$sha"
  check_compiles "$run"
  check_cache "$run"
  check_budget
  [ -z "$mode" ] || check_wall "$run" "$mode"
  [ -z "$base" ] || check_coverage "$run" "$base"
  check_macos "$run"
  check_env "$run"
  if [ -n "$base" ]; then check_shards "$run" --base "$base"; else check_shards "$run"; fi
}

dispatch() {
  local c=${1:-}
  [ $# -ge 1 ] && shift
  case $c in
    runs) check_runs "$@" ;;
    compiles) check_compiles "$@" ;;
    cache) check_cache "$@" ;;
    budget) check_budget "$@" ;;
    wall) check_wall "$@" ;;
    seeded) [ $# -ge 2 ] || usage; check_seeded "$@" ;;
    coverage) check_coverage "$@" ;;
    macos) check_macos "$@" ;;
    env) check_env "$@" ;;
    shards) [ $# -ge 1 ] || usage; check_shards "$@" ;;
    all) [ $# -ge 1 ] || usage; check_all "$@" ;;
    *) usage ;;
  esac
}

if [ "${1:-}" = --self-test ]; then
  [ $# -eq 1 ] || usage
  FIX="$HERE/run-checks"
  [ -d "$FIX" ] || { echo "run-checks.sh self-test FAIL: no fixtures in $FIX"; exit 1; }
  ST=$(mktemp -d "${TMPDIR:-/tmp}/run-checks-test.XXXXXX")
  trap 'rm -r "$WORK" "$ST"' EXIT
  fails=0 cases=0
  # the stand-in gh: answers from the fixtures (one JSON per run: its record, its jobs with their logs, its artifacts)
  cat > "$ST/gh" <<'GH'
#!/usr/bin/env bash
case $1 in
  run) run=$3 dir=""
       while [ $# -gt 0 ]; do [ "$1" != -D ] || dir=$2; shift; done
       jq -r '(.artifacts // {}) | to_entries[] | .key as $a | .value | to_entries[] | [$a, .key, (.value | tojson)] | @tsv' \
         "$FIX/$run.json" | while IFS=$'\t' read -r a f j; do mkdir -p "$dir/$a"; printf '%s\n' "$j" > "$dir/$a/$f"; done ;;
  api) path=""
       for a in "$@"; do case $a in repos/*) path=$a ;; esac; done
       case $path in
         */actions/runs/*/jobs*) r=${path#*/actions/runs/}; jq '{jobs: [.jobs[] | del(.log)]}' "$FIX/${r%%/*}.json" ;;
         */actions/runs\?head_sha=*) s=${path#*head_sha=}; jq --arg s "${s%%&*}" '{workflow_runs: .[$s]}' "$FIX/heads.json" ;;
         */actions/runs/*) jq .run "$FIX/${path##*/}.json" ;;
         */actions/jobs/*/logs) j=${path#*/actions/jobs/}
                                for f in "$FIX"/[0-9]*.json; do jq -r --argjson j "${j%%/*}" '.jobs[] | select(.id == $j) | .log // empty' "$f"; done ;;
         */commits/*) printf '{"sha":"%s"}\n' "${path##*/}" ;;
         */actions/cache/usage) cat "$ST/usage.json" ;;
         */actions/caches*) cat "$ST/caches.json" ;;
         *) exit 1 ;;
       esac ;;
  *) exit 1 ;;
esac
GH
  chmod +x "$ST/gh"
  export FIX ST
  GH="$ST/gh"
  # cargo metadata of a target with 100 third-party packages (dep-001 … dep-100) and two workspace members
  jq -n '[range(1; 101) | "dep-\(. | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end)"] as $d
         | {workspace_members: ["ws#ratatoskr@0.1.0", "ws#ws-b@0.1.0"],
            packages: ([$d[] | {id: "reg#\(.)@1.0.0", name: .}] + [{id: "ws#ratatoskr@0.1.0", name: "ratatoskr"}, {id: "ws#ws-b@0.1.0", name: "ws-b"}]),
            resolve: {nodes: ([$d[] | {id: "reg#\(.)@1.0.0"}] + [{id: "ws#ratatoskr@0.1.0"}, {id: "ws#ws-b@0.1.0"}])}}' > "$ST/metadata.json"
  echo 1.100.0 > "$ST/rust-version"
  export CHECKS_METADATA="$ST/metadata.json"
  RUST_VERSION_FILE="$ST/rust-version"
  # expect VERDICT N ARGS...: `check N: VERDICT` and the matching exit status
  expect() {
    local want=$1 n=$2 out st
    shift 2
    cases=$((cases + 1))
    out=$( (RC=0; dispatch "$@"; exit "$RC") 2>&1 ); st=$?
    if ! printf '%s\n' "$out" | grep -q "^check $n: $want"; then
      echo "run-checks.sh self-test FAIL: $* => want check $n: $want, got: $out"; fails=$((fails + 1))
    elif { [ "$want" = PASS ] && [ "$st" != 0 ]; } || { [ "$want" = FAIL ] && [ "$st" != 1 ]; }; then
      echo "run-checks.sh self-test FAIL: $* => exit $st for $want"; fails=$((fails + 1))
    fi
    [ -z "${CHECKS_VERBOSE:-}" ] || printf '%s\n' "$out"
    LAST=$out
  }
  # 1: a push on a ci branch and the pull request for one SHA; one pull request and one push on main
  expect FAIL 1 runs aaaa
  expect PASS 1 runs bbbb
  # 2: a consumer (second job) compiles serde; the hub ×3 in fedora's build under its budget of 3; ×4
  expect FAIL 2 compiles 101
  expect PASS 2 compiles 102
  expect FAIL 2 compiles 103
  # 3: restored across the toolchain; no cache; the same toolchain and 3 of 100 third-party; 6 of 100
  expect FAIL 3 cache 111
  expect FAIL 3 cache 112
  expect PASS 3 cache 102
  expect FAIL 3 cache 114
  # 4: 10.2 GiB; a main entry gone; under the limit with main's entries there
  printf '{"active_caches_size_in_bytes": %s, "active_caches_count": 9}\n' $((102 * GIB / 10)) > "$ST/usage.json"
  expect FAIL 4 budget
  printf '{"active_caches_size_in_bytes": %s, "active_caches_count": 9}\n' $((4 * GIB)) > "$ST/usage.json"
  printf '%s\n' '{"actions_caches": [{"key": "cargo-a", "ref": "refs/heads/main"}, {"key": "cargo-b", "ref": "refs/heads/main"}, {"key": "cargo-p", "ref": "refs/pull/5/merge"}]}' > "$ST/before.json"
  printf '%s\n' '{"actions_caches": [{"key": "cargo-a", "ref": "refs/heads/main"}]}' > "$ST/caches.json"
  expect FAIL 4 budget --before "$ST/before.json"
  printf '%s\n' '{"actions_caches": [{"key": "cargo-a", "ref": "refs/heads/main"}]}' '{"actions_caches": [{"key": "cargo-b", "ref": "refs/heads/main"}]}' > "$ST/caches.json"
  expect PASS 4 budget --before "$ST/before.json"
  # 5: 20 minutes to the gate; 30
  expect PASS 5 wall 171 --warm
  expect FAIL 5 wall 172 --warm
  expect PASS 5 wall 172 --cold
  # 6: the gate green with a consumer skipped; both failed
  expect FAIL 6 seeded 121 --gate-fails --failed escape
  expect PASS 6 seeded 122 --gate-fails --failed escape
  # 7: 6,327 tests against 6,326; the same run against itself
  expect FAIL 7 coverage 152 151
  expect PASS 7 coverage 151 151
  # 8: five macOS jobs at once; four, and a fifth after them
  expect FAIL 8 macos 131
  expect PASS 8 macos 132
  # 9: rustc 1.99.1 where rust-version says 1.100.0; the pinned rustc and the image's digest
  expect FAIL 9 env 141
  expect PASS 9 env 142
  # 10: a tests 2/2 log with no shard-stats line; a 13 GiB peak passes with a warning
  expect FAIL 10 shards 161
  expect PASS 10 shards 162
  printf '%s\n' "$LAST" | grep -q '^::warning::' || { echo "run-checks.sh self-test FAIL: shards 162 => no ::warning:: for 13 GiB"; fails=$((fails + 1)); }
  # the repository's budget: the build rows are builds, the consumers compile nothing, an unknown job has no row
  [ "$(budget_of 'Runtime / escape suite on the runner (ubuntu-24.04)')" = "0 0" ] || { echo "run-checks.sh self-test FAIL: the escape legs are not consumers in $BUDGET"; fails=$((fails + 1)); }
  ! budget_of 'Runtime / no such job' >/dev/null || { echo "run-checks.sh self-test FAIL: an unknown job has a row in $BUDGET"; fails=$((fails + 1)); }
  if [ "$fails" -eq 0 ]; then echo "run-checks.sh self-test: ok ($cases cases)"; exit 0; fi
  exit 1
fi

dispatch "$@"
exit "$RC"

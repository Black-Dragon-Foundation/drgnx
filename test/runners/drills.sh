#!/usr/bin/env bash
# The link drills (drgnx-ratatoskr's tests/fleet_drills.rs), each row N times, on a fake fleet of 2 runners whose sshd
# allows 3 sessions per connection. Run it through the heavy slot like fleet.sh (`$HEAVY drills.sh --container ...`).
#   drills.sh [--times N] [--timing] [FILTER]     N defaults to 5, FILTER to drill::
# DRGNX_FLEET_TEST_BIN is the fleet_drills test binary, with the test-hooks `sleipnir` and `drgnx-key` beside its deps/
# (as fleet.sh test takes it):
#   cargo test -p drgnx-ratatoskr --features fleet,test-hooks --test fleet_drills --no-run
#   cargo build -p sleipnir --features test-hooks --bin sleipnir --bin drgnx-key
# The fleet throughput row (a timing row) runs only with --timing. Rows run one at a time, round by round (every row
# once, then again), each run in its own log under .claude/tmp/drills/. Prints `ROW RUN ok|FAILED` per run, then
# `ROW PASSED/N` per row; exit 0 only when every run passed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
times=5 timing=0 filter=drill::
[ "${1:-}" = --container ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --times) times=$2; shift 2 ;;
    --timing) timing=1; shift ;;
    -*) echo "drills.sh: unknown option $1" >&2; exit 2 ;;
    *) filter=$1; shift ;;
  esac
done
: "${DRGNX_FLEET_TEST_BIN:?set DRGNX_FLEET_TEST_BIN to the fleet_drills test binary}"
logs=$top/.claude/tmp/drills
mkdir -p "$logs"
fleet() { bash "$here/fleet.sh" "$@"; }
fleet down >/dev/null 2>&1 || true
trap 'fleet down >/dev/null 2>&1 || true' EXIT
fleet up --runners 2 --max-sessions 3
rows=$(fleet test --list "$filter" 2>/dev/null | sed -n 's/: test$//p')
[ "$timing" = 1 ] || rows=$(printf '%s\n' "$rows" | grep -v '::a_set_spreads_' || true)
[ -n "$rows" ] || { echo "drills.sh: no row matches $filter" >&2; exit 2; }
declare -A passed
for row in $rows; do passed[$row]=0; done
for n in $(seq 1 "$times"); do
  for row in $rows; do
    log=$logs/${row//::/-}.$n.log
    rc=0; fleet test --test-threads=1 --exact "$row" > "$log" 2>&1 || rc=$?
    if [ "$rc" = 0 ] && grep -q '^test result: ok. 1 passed' "$log"; then
      passed[$row]=$((passed[$row] + 1)); echo "$row $n ok"
    else
      echo "$row $n FAILED (exit $rc, $log)"; grep -E -A2 'panicked|^thread' "$log" | head -8 | cut -c1-600 || true
    fi
  done
done
all=0
echo "=== drills: each row $times times"
for row in $rows; do
  echo "$row ${passed[$row]}/$times"
  [ "${passed[$row]}" = "$times" ] || all=1
done
exit $all

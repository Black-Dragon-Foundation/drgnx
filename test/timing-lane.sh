#!/usr/bin/env bash
# drgnx's timing lane (report-only): the :timing tests, judged against the runner's own speed.
#   test/timing-lane.sh --report F [--rows FILE] [--samples N] [--runner EXE]
#   test/timing-lane.sh --self-test
#   test/timing-lane.sh --calibrate          (one calibration: its seconds)
# Every CI tier sets DRGNX_TEST_NO_TIMING=1, so the tests tagged :timing (wall-clock assertions) run nowhere else; this
# lane is their one place.  Each row of timing-rows.txt (`NAME BUDGET-RATIO`) is a set of them: NAME `all` is every
# :timing test of the live files (exempt files carry no class, so no tag), any other NAME the :timing tests whose name
# starts with it: the rows are the areas' prefixes, so each area is judged on its own time.  A row takes N (20) samples,
# each one `bin/drgnx test --container` run with DRGNX_TEST_TIME_FACTOR = calibration / reference calibration (at
# least 1), and is judged on the MEDIAN of the samples' times divided by the calibration: the time a fixed ~1 s workload
# takes on this runner, measured before and after the row.  Rules (Nidhogg's):
#   - the two calibrations differ by over 25 %: the attempt is void and retried once; void twice prints `void`, never red;
#   - a median over BUDGET-RATIO, or over half the samples failing, is a red;
#   - a red reruns once with fresh calibrations; a pass on the rerun is `flaky`, two reds are `red`.
# F gets one line per row: `ROW VERDICT median=X ratio=R calibration=C fails=K/N (note)`, VERDICT pass|flaky|red|void.
# Exit 0 always while the lane is report-only (2 on a usage error).
# A sample is EXE TARGET (--runner), which prints the seconds the run took and exits 0 when it passed; the default runs
# bin/drgnx.  TARGET `calibration` is the workload: DRGNX_TIMING_CALIB_CMD, else a batch Emacs in the image the tests
# run in (DRGNX_TEST_IMAGE, which CI's test-image step sets, else drgnx-test:f45; DRGNX_CONTAINER, else podman), so the
# calibration and the samples share one Emacs and one runtime; the workload times itself, the container's start is out.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
rows="$here/timing-rows.txt" samples=20 runner="" report="" self=0 calonly=0
while [ $# -gt 0 ]; do
  case $1 in
    --calibrate) calonly=1; shift ;;
    --report) report=${2:?}; shift 2 ;;
    --rows) rows=${2:?}; shift 2 ;;
    --samples) samples=${2:?}; shift 2 ;;
    --runner) runner=${2:?}; shift 2 ;;
    --self-test) self=1; shift ;;
    *) sed -n '2,3p' "$0" >&2; exit 2 ;;
  esac
done

# the reference calibration (`# island-calibration` in the rows: a pinned host's, which the budgets were set on): a
# runner slower than it gets proportionally longer wall-clock budgets in the tests (DRGNX_TEST_TIME_FACTOR)
island=$(sed -nE 's/^# island-calibration ([0-9.]+).*/\1/p' "$rows" 2>/dev/null | head -n 1); island=${island:-1}
factor=1

workload='(let ((n 0.0) (t0 (float-time))) (dotimes (_ 1500000) (setq n (+ n (string-to-number "12345.678")))) (with-temp-buffer (dotimes (i 300000) (insert (number-to-string i) "\n"))) (princ (format "%.4f" (- (float-time) t0))))'

default_sample() {
  local t=$1 sel log rc secs
  if [ "$t" = calibration ]; then
    if [ -n "${DRGNX_TIMING_CALIB_CMD:-}" ]; then bash -c "$DRGNX_TIMING_CALIB_CMD"
    else "${DRGNX_CONTAINER:-podman}" run --rm --memory 1g --memory-swap 1g "${DRGNX_TEST_IMAGE:-drgnx-test:f45}" \
           /usr/local/bin/emacs --batch -Q --eval "$workload" </dev/null; fi
    return $?
  fi
  if [ "$t" = all ]; then sel='(tag :timing)'; else sel="(and (tag :timing) \"^$t\")"; fi
  log=$(mktemp)
  env -u DRGNX_TEST_NO_TIMING DRGNX_TEST_TIME_FACTOR="$factor" DRGNX_TEST_SELECTOR="$sel" \
    "$root/bin/drgnx" test --container >"$log" 2>&1 </dev/null; rc=$?
  secs=$(sed -nE 's/^drgnx: [0-9]+ test files.*\(([0-9.]+) s\)$/\1/p' "$log" | tail -n 1)
  rm -f "$log"; echo "${secs:-0}"; return "$rc"
}
sample() { if [ -n "$runner" ]; then "$runner" "$1"; else default_sample "$1"; fi; }

median() { sort -g | awk '{a[NR]=$1} END {if (NR == 0) {print 0} else if (NR % 2) {print a[(NR+1)/2]} else {printf "%.6f\n", (a[NR/2]+a[NR/2+1])/2}}'; }
calib() { sample calibration 2>/dev/null | tail -n 1; }

# one attempt at a row: prints "VERDICT MEDIAN RATIO CAL FAILS" (VERDICT pass|red|void)
attempt() { # ROW BUDGET
  local row=$1 budget=$2 c1 c2 cal i s rc fails=0 vals="" med ratio dev
  c1=$(calib)
  factor=$(awk -v c="$c1" -v i="$island" 'BEGIN {f = (i > 0) ? c / i : 1; printf "%.3f", (f < 1) ? 1 : f}')
  for ((i = 0; i < samples; i++)); do
    s=$(sample "$row" 2>/dev/null); rc=$?
    s=$(tail -n 1 <<<"$s")
    [ "$rc" = 0 ] || fails=$((fails + 1))
    vals+="${s:-0}"$'\n'
  done
  c2=$(calib)
  dev=$(awk -v a="$c1" -v b="$c2" 'BEGIN {m = (a < b) ? a : b; if (m <= 0) print 99; else printf "%.4f", ((a > b ? a : b) - m) / m}')
  cal=$(awk -v a="$c1" -v b="$c2" 'BEGIN {printf "%.4f", (a + b) / 2}')
  med=$(printf '%s' "$vals" | median)
  ratio=$(awk -v m="$med" -v c="$cal" 'BEGIN {if (c <= 0) print 0; else printf "%.3f", m / c}')
  if awk -v d="$dev" 'BEGIN {exit !(d > 0.25)}'; then echo "void $med $ratio $cal $fails"; return; fi
  if awk -v r="$ratio" -v b="$budget" 'BEGIN {exit !(r > b)}' || [ $((fails * 2)) -gt "$samples" ]; then echo "red $med $ratio $cal $fails"
  else echo "pass $med $ratio $cal $fails"; fi
}

judge_row() { # ROW BUDGET -> one report line
  local row=$1 budget=$2 v med ratio cal fails note=""
  read -r v med ratio cal fails < <(attempt "$row" "$budget")
  if [ "$v" = void ]; then
    note="void once: calibrations over 25% apart, retried"
    read -r v med ratio cal fails < <(attempt "$row" "$budget")
    if [ "$v" = void ]; then echo "$row void median=$med ratio=$ratio calibration=$cal fails=$fails/$samples (void twice: the runner's speed moved over 25% during the run; not a failure)"; return; fi
  fi
  if [ "$v" = red ]; then
    note="${note:+$note; }red once, rerun with fresh calibration"
    read -r v med ratio cal fails < <(attempt "$row" "$budget")
    case $v in
      pass) v=flaky ;;
      void) note="$note; the rerun was void"; v=red ;;
    esac
  fi
  echo "$row $v median=$med ratio=$ratio calibration=$cal fails=$fails/$samples (budget $budget${note:+; $note})"
}

run_lane() {
  : > "$report"
  while read -r row budget _; do
    [ -n "$row" ] || continue
    judge_row "$row" "$budget" >> "$report"
  done < <(sed 's/#.*//' "$rows" | awk 'NF')
  cat "$report"
}

self_test() {
  local d rc=0 out
  d=$(mktemp -d) || return 1
  trap 'rm -rf "$d"' RETURN
  # the fake runner reads one line `SECONDS STATUS` per call from $d/script, in order
  cat > "$d/run" <<'EOF'
#!/usr/bin/env bash
d=$(dirname "$0"); n=$(cat "$d/n" 2>/dev/null || echo 1)
line=$(sed -n "${n}p" "$d/script"); echo $((n + 1)) > "$d/n"
[ -n "$line" ] || line="1.0 0"
set -- $line; echo "$1"; exit "$2"
EOF
  chmod +x "$d/run"
  printf 'row-a 2.0\n' > "$d/rows"
  try() { # name expected-verdict ; script on stdin
    cat > "$d/script"; rm -f "$d/n"
    out=$(bash "$0" --runner "$d/run" --rows "$d/rows" --samples 4 --report "$d/rep"); local r=$?
    if [ "$r" != 0 ] || ! grep -q "^row-a $2 " <<<"$out"; then echo "FAIL: $1: wanted $2, got (exit $r): $out"; rc=1; fi
  }
  # an attempt is a calibration, 4 samples, a calibration: 6 calls
  try pass pass <<'EOF'
1.0 0
1.5 0
1.5 0
1.4 0
1.6 0
1.1 0
EOF
  try void-twice void <<'EOF'
1.0 0
1.5 0
1.5 0
1.5 0
1.5 0
2.0 0
1.0 0
1.5 0
1.5 0
1.5 0
1.5 0
2.0 0
EOF
  try red-then-pass flaky <<'EOF'
1.0 0
3.0 0
3.0 0
3.0 0
3.0 0
1.0 0
1.0 0
1.5 0
1.5 0
1.5 0
1.5 0
1.0 0
EOF
  try red-twice red <<'EOF'
1.0 0
3.0 0
3.0 0
3.0 0
3.0 0
1.0 0
1.0 0
3.0 0
3.0 0
3.0 0
3.0 0
1.0 0
EOF
  # over half the samples failing: red (two of four is not over half, three is)
  try failing-samples red <<'EOF'
1.0 0
1.5 1
1.5 1
1.5 1
1.5 0
1.0 0
1.0 0
1.5 1
1.5 1
1.5 1
1.5 0
1.0 0
EOF
  # the calibration runs in the tests' image, with its own Emacs: never a host Emacs (a CI runner has none)
  cat > "$d/ctr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/ctr-args"; echo 0.5
EOF
  chmod +x "$d/ctr"
  out=$(DRGNX_CONTAINER="$d/ctr" DRGNX_TEST_IMAGE=drgnx-test:probe DRGNX_TIMING_CALIB_CMD='' bash "$0" --calibrate)
  if [ "$out" != 0.5 ] || ! grep -qx 'drgnx-test:probe' "$d/ctr-args" || ! grep -qx /usr/local/bin/emacs "$d/ctr-args"; then
    echo "FAIL: calibration: wanted a run of drgnx-test:probe's /usr/local/bin/emacs, got $out: $(tr '\n' ' ' < "$d/ctr-args" 2>/dev/null)"
    rc=1
  fi
  [ "$rc" != 0 ] || echo "timing-lane self-test: ok"
  return "$rc"
}

if [ "$self" = 1 ]; then self_test; exit $?; fi
if [ "$calonly" = 1 ]; then default_sample calibration; exit $?; fi
[ -n "$report" ] || { sed -n '2,3p' "$0" >&2; exit 2; }
run_lane
exit 0

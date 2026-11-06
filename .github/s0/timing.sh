#!/usr/bin/env bash
# S0 timings: P5 (the attach path's cost; VM gate) and P8 (the sidecar's start; laptop). Local only (org folder).
# Usage: timing.sh p5 PATH...  |  timing.sh p8
# Env: S0_BYTES (100000000), S0_RUNS (5), S0_WORK (work dir; the laptop passes one under the org folder).
D=$(cd "$(dirname "$0")" && pwd)
. "$D/lib.sh"
trap cleanup EXIT
export LC_ALL=C
N=${S0_BYTES:-100000000}
RUNS=${S0_RUNS:-5}
HZ=$(getconf CLK_TCK)

ticks() { if [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ]; then awk '{print $14 + $15}' "/proc/$1/stat"; else echo 0; fi; }
# the service re-executes itself inside the rootless user namespace: count it and its children
srvticks() {
  local p t=0 c
  [ -n "${SRVPID:-}" ] || { echo 0; return; }
  for p in "$SRVPID" $(cat "/proc/$SRVPID/task/"*/children 2>/dev/null); do c=$(ticks "$p"); t=$((t + c)); done
  echo "$t"
}
stats() {  # numbers on stdin -> median, p90, n
  sort -g | awk '{a[NR] = $1} END {
    if (NR == 0) { print "n 0"; exit }
    m = (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2
    i = int(NR * 0.9 + 0.9999); if (i > NR) i = NR
    printf "median %.4g p90 %.4g n %d", m, a[i], NR }'
}
med() { printf '%s\n' "$@" | stats | awk '{print $2}'; }

# one transfer: DIR BYTES -> "dt conmon_s server_s client_s" (seconds; the CPU figures are totals up to DONE)
xfer() {
  local dir=$1 n=$2 name=bld-s0-p5 cmd s0 t0 out
  case $dir in
    to) cmd='cat >/dev/null; echo DONE; sleep 2' ;;
    from) cmd="head -c $n /dev/zero; echo DONE; sleep 2" ;;
    both) cmd='cat; echo DONE; sleep 2' ;;
  esac
  s0=$(srvticks)
  TIMEFORMAT='TIME %U %S'
  t0=$EPOCHREALTIME
  out=$({ time {
    if [ "$dir" = from ]; then head -c 0 /dev/zero; else head -c "$n" /dev/zero; fi |
      "${P[@]}" run -i --rm --log-driver=none --detach-keys= --name $name "$B" sh -c "$cmd" |
      {
        [ "$dir" != to ] && head -c "$n" >/dev/null
        IFS= read -r l; t1=$EPOCHREALTIME
        echo "SAMPLE $l $t1 $(ticks "$(podman inspect --format '{{.State.ConmonPid}}' $name 2>/dev/null)") $(srvticks)"
        cat >/dev/null
      }
  }; } 2>&1)
  echo "$out" | awk -v t0="$t0" -v s0="$s0" -v hz="$HZ" '
    /^SAMPLE DONE/ { dt = $3 - t0; c = $4 / hz; s = ($5 - s0) / hz; ok = 1 }
    /^TIME/ { u = $2 + $3 }
    !/^SAMPLE|^TIME/ { err = err $0 " " }
    END { if (!ok) { print "FAIL " err; exit } printf "%.4f %.3f %.3f %.3f\n", dt, c, s, u }'
}

p5() {
  set_path "$1"
  say "P5 on $PATHNAME ($("${P[@]}" version --format '{{.Server.Version}}')): $RUNS runs of $N bytes per direction"
  local dir k r b0 c0 s0 u0 a b c d f
  for dir in to from both; do
    local bd=() bc=() bs=() bu=()
    for ((k = 0; k < RUNS; k++)); do
      f=($(xfer "$dir" 0)); a=${f[0]:-FAIL} b=${f[1]:-} c=${f[2]:-} d=${f[3]:-}
      [ "$a" = FAIL ] && { echo "baseline $dir: FAIL $b $c $d"; continue; }
      bd+=("$a"); bc+=("$b"); bs+=("$c"); bu+=("$d")
    done
    b0=$(med "${bd[@]}"); c0=$(med "${bc[@]}"); s0=$(med "${bs[@]}"); u0=$(med "${bu[@]}")
    echo "$dir: baseline (0 bytes) median: start-to-DONE ${b0}s conmon ${c0}s server ${s0}s client ${u0}s"
    local rr=() rn=() rc=() rs=() ru=()
    for ((k = 0; k < RUNS; k++)); do
      r=$(xfer "$dir" "$N")
      echo "  $dir run $k: $r"
      f=($r); a=${f[0]:-FAIL} b=${f[1]:-} c=${f[2]:-} d=${f[3]:-}
      [ "$a" = FAIL ] && continue
      rr+=("$(awk -v n="$N" -v t="$a" 'BEGIN{printf "%.1f", n / 1e6 / t}')")
      rn+=("$(awk -v n="$N" -v t="$a" -v z="$b0" 'BEGIN{printf "%.1f", n / 1e6 / (t - z)}')")
      rc+=("$(awk -v x="$b" -v z="$c0" 'BEGIN{printf "%.3f", x - z}')")
      rs+=("$(awk -v x="$c" -v z="$s0" 'BEGIN{printf "%.3f", x - z}')")
      ru+=("$(awk -v x="$d" -v z="$u0" 'BEGIN{printf "%.3f", x - z}')")
    done
    echo "$dir: MB/s raw $(printf '%s\n' "${rr[@]}" | stats); net of start $(printf '%s\n' "${rn[@]}" | stats)"
    echo "$dir: CPU s per $N bytes: conmon $(printf '%s\n' "${rc[@]}" | stats); server $(printf '%s\n' "${rs[@]}" | stats); client pipeline $(printf '%s\n' "${ru[@]}" | stats)"
  done
  rt
}

rt() {  # 200 sequential 1 KiB round trips through cat
  local blk i a b x wfd out=()
  blk=$(printf 'a%.0s' $(seq 1024))
  coproc RTC { "${P[@]}" run -i --rm --log-driver=none --detach-keys= --name bld-s0-rt "$B" cat 2>&1; }
  PIDS+=("$RTC_PID"); wfd=${RTC[1]}
  for ((i = 0; i <= 200; i++)); do
    a=${EPOCHREALTIME/./}
    printf '%s' "$blk" >&"$wfd"
    IFS= read -r -N 1024 -u "${RTC[0]}" x || { note "rt: short read at $i"; break; }
    b=${EPOCHREALTIME/./}
    [ $i -gt 0 ] && out+=($((b - a)))
  done
  exec {wfd}>&-
  wait "$RTC_PID"
  echo "round trips (1 KiB, us, the first one dropped): $(printf '%s\n' "${out[@]}" | stats)"
}

p8() {
  set_path local
  say "P8 on $(hostname -s): podman $(podman version --format '{{.Client.Version}}'), $(podman ps -q | wc -l) containers running"
  local i t0 t1 x out=()
  if ! podman image exists "$PX"; then
    podman import -q --change 'ENTRYPOINT ["/px"]' "$W/px.tar" "$PX" >/dev/null || { echo "import failed"; return; }
  fi
  for ((i = 0; i < 20; i++)); do
    t0=$EPOCHREALTIME
    { IFS= read -r -n 1 x; t1=$EPOCHREALTIME; cat >/dev/null; } < <(podman run "${SIDE[@]}" --name bld-s0-p8 "$PX" --version </dev/null 2>&1)
    wait $!
    out+=("$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b - a}')")
  done
  echo "runs: ${out[*]}"
  echo "start to first stdout byte, s: $(printf '%s\n' "${out[@]}" | stats)"
}

sec=$1; shift
case $sec in
  p5)
    SRVPID=
    if [[ " $* " == *" remote "* || " $* " == *" ssh "* ]]; then
      mkdir -p "$(dirname "$SOCK")"; rm -f "$SOCK"
      podman system service --time=0 "unix://$SOCK" & SRVPID=$!; PIDS+=("$SRVPID")
      timeout 20 bash -c "until [ -S '$SOCK' ]; do sleep 0.1; done"
    fi
    for p in "$@"; do p5 "$p"; done ;;
  p8) p8 ;;
  *) echo "usage: timing.sh p5 PATH... | p8" >&2; exit 2 ;;
esac

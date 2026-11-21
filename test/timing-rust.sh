#!/usr/bin/env bash
# The Rust half of drgnx's timing lane (report-only): the `#[ignore = "timing: …"]` tests under runtime/, which every
# other Rust job leaves out (a shared runner's clock judges nothing there).
#   test/timing-rust.sh [--report F]            run them from a Fedora 45 container (DRGNX_CONTAINER, else podman): the
#                                               prebuilt DRGNX_TEST_RUST_IMAGE (test/container/Containerfile.rust, which
#                                               CI's test-image step sets), else plain Fedora 45 and its Rust from dnf
#   test/timing-rust.sh --inside [--report F]   the same in this environment (the container runs this)
# Each row of timing-rust.txt is one test run alone (--test-threads 1); F gets one line per row, `ROW pass|red`.
# Exit 0 always (report-only: a red verdict never reddens the run), 2 on a usage error.  The checkout is mounted
# read-only, the cargo target directory is a tmpfs, and the container is memory-capped.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
rows=$root/test/timing-rust.txt
report=""
inside=0
while [ $# -gt 0 ]; do
  case $1 in
    --report) report=$2; shift 2 ;;
    --inside) inside=1; shift ;;
    *) echo "usage: timing-rust.sh [--inside] [--report F]" >&2; exit 2 ;;
  esac
done
emit() { if [ -n "$report" ]; then tee "$report"; else cat; fi; }

if [ "$inside" = 0 ]; then
  "${DRGNX_CONTAINER:-podman}" run --rm --init --memory 6g --memory-swap 6g --tmpfs /tmp/target:size=4g \
    -v "$root:/src:ro,z" -w /src "${DRGNX_TEST_RUST_IMAGE:-registry.fedoraproject.org/fedora:45}" \
    bash test/timing-rust.sh --inside </dev/null | emit
  exit 0
fi

command -v cargo >/dev/null 2>&1 || dnf -y -q install cargo rust gcc >/dev/null 2>&1 || { echo "timing-rust: no toolchain"; exit 0; }
export CARGO_TARGET_DIR=/tmp/target CARGO_TERM_COLOR=never
out=$(mktemp)
sed 's/#.*//' "$rows" | awk 'NF' | while read -r crate target test mode; do
  # a fleet row needs the fake fleet: test/runners/drills.sh --timing runs it
  if [ "${mode:-}" = fleet ]; then echo "$crate::$test fleet (drills.sh --timing)"; continue; fi
  args=(test --locked --manifest-path "$root/runtime/Cargo.toml" -p "$crate")
  [ "$crate" = drgnx-ratatoskr ] && args+=(--features drgnx-ratatoskr/test-hooks)
  [ "${mode:-}" = release ] && args+=(--release)
  if [ "$target" = lib ]; then args+=(--lib); else args+=(--test "$target"); fi
  if cargo "${args[@]}" -- --ignored --test-threads 1 "$test" >"$out" 2>&1 && grep -q '^test result: ok. 1 passed' "$out"; then
    echo "$crate::$test pass"
  else
    echo "$crate::$test red ($(grep -m1 -E 'panicked|error' "$out" | cut -c1-120))"
  fi
done | emit
rm -f "$out"
exit 0

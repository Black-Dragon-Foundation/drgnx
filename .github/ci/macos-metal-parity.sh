#!/bin/bash
# macos-metal-parity.sh: Hrafn's embedder on Metal (macos.yml, on demand: `only: metal-parity`).  On macOS the GPU
# rows (hrafn-embed's tests/parity_gpu.rs, drgnx-ratatoskr's tests/search_index.rs) are ignored in the workspace run;
# here they run with --ignored on the first Metal adapter wgpu lists (not a software one), named by DRGNX_TEST_ADAPTER.
# The adapters found are printed first.  A runner with no Metal adapter fails with that reason: the Metal claim then
# rests on a real Mac.  Needs DRGNX_TEST_MODELS (the model files); run from the checkout's root.
set -uo pipefail
: "${DRGNX_TEST_MODELS:?DRGNX_TEST_MODELS: the model files (models.sh) first}"
say() { echo "metal-parity: $*"; }
cargo_test() { cargo test --locked --no-fail-fast --manifest-path runtime/Cargo.toml "$@"; }

listing=$(cargo_test -p hrafn-embed --test parity_gpu -- --ignored --exact lists_the_adapters --nocapture 2>&1) || {
  echo "$listing"
  say "FAIL the adapter listing did not run"
  exit 1
}
adapters=$(grep '^ADAPTER' <<< "$listing")
say "adapters wgpu lists:"
echo "${adapters:-  (none)}"
adapter=$(awk -F'\t' '$4 == "true" && $3 != "Software" { print $2; exit }' <<< "$adapters")
if [[ -z "$adapter" ]]; then
  say "FAIL no Metal adapter on this runner: the GPU rows cannot run here, and Metal parity rests on a real Mac"
  exit 1
fi
say "running the GPU rows on $adapter"
export DRGNX_TEST_ADAPTER=$adapter
fail=0
# the 20-chunk rows read reference vectors the CI model set does not hold: a real Mac's, as on Linux
cargo_test -p hrafn-embed --test parity_gpu -- --ignored --skip lists_the_adapters --skip full_references || fail=1
cargo_test -p drgnx-ratatoskr --features test-hooks --test search_index -- --ignored || fail=1
if [[ $fail = 0 ]]; then say "ok on $adapter"; else say "FAIL on $adapter"; fi
exit $fail

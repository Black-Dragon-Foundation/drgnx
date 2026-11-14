#!/usr/bin/env bash
# Mutation checks: each patch breaks one guard on purpose, and the row or test it names must go red.
#
#   test/mutations/run.sh PATCH [TARGET]   apply PATCH, build, run TARGET, expect a red, revert
#   test/mutations/run.sh --list           print every patch and its target
#
# A patch's target is its `Target:` line (TARGET overrides it): `row GROUP/NAME` runs that conformance row with domr
# (`--require-all`, so a skip is not a red), `test CRATE NAME [FEATURES]` runs that cargo test (with FEATURES, for a test
# behind one).  A green under the patch fails the
# check: the guard is not tested.  The patch is reverted whatever happens.  Run from the checkout's root, on a host
# that can run the target (the container-escape rows need rootless podman: CI's Ubuntu lane, the Fedora VM gate).
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

target_of() {
    sed -n 's/^Target: //p' "$1" | head -n 1
}

if [ "${1:-}" = "--list" ]; then
    for p in test/mutations/*/*.patch; do
        printf '%s -> %s\n' "$p" "$(target_of "$p")"
    done
    exit 0
fi

patch=${1:?usage: run.sh PATCH [TARGET] | --list}
shift
target=${*:-$(target_of "$patch")}
[ -n "$target" ] || { echo "run.sh: $patch names no Target" >&2; exit 2; }

git apply --check "$patch"
git apply "$patch"
trap 'git apply -R "$patch"' EXIT

set -- $target
kind=$1
shift
status=0
case $kind in
    row)
        cargo build --manifest-path runtime/Cargo.toml --locked -p drgnx-ratatoskr -p drgnx-px -p domr \
            --features drgnx-ratatoskr/test-hooks
        runtime/target/debug/domr --hub-bin runtime/target/debug/ratatoskr \
            --scenarios test/conformance --only "$1" --require-all || status=$?
        ;;
    test)
        cargo test --manifest-path runtime/Cargo.toml --locked -p "$1" ${3:+--features "$3"} -- --exact "$2" || status=$?
        ;;
    *)
        echo "run.sh: unknown target kind: $kind" >&2
        exit 2
        ;;
esac

if [ "$status" -eq 0 ]; then
    echo "MUTANT SURVIVED: $patch ($target stayed green)"
    exit 1
fi
echo "killed: $patch ($target went red)"

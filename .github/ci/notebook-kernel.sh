#!/usr/bin/env bash
# The live notebook rows' kernel (runtime/crates/drgnx-ratatoskr/src/notebook/kernel/tests_live.rs): ipykernel in a venv, from
# test/container/ipykernel-requirements.txt, every file checked against the hash it names (pip --require-hashes; the set is
# complete, so --no-deps). Prints the variable the rows read, for `>> "$GITHUB_ENV"` or `eval`. The adapter image does the same at
# /opt/nb-kernel (test/container/debug-adapters-image.sh), from the same file.
# DRGNX_ADAPTER_PYTHON (default python3) makes the venv.
# Usage: notebook-kernel.sh DIR
set -euo pipefail
dir=${1:?usage: notebook-kernel.sh DIR}
repo=$(cd "$(dirname "$0")/../.." && pwd)
py=${DRGNX_ADAPTER_PYTHON:-python3}
mkdir -p "$dir"
"$py" -m venv "$dir/venv"
"$dir/venv/bin/pip" install --quiet --require-hashes --no-deps -r "$repo/test/container/ipykernel-requirements.txt" >&2
# a gap in the pinned set (a dependency this python needs and the file lacks) shows here, not in a test
"$dir/venv/bin/python3" -c 'import ipykernel, ipykernel_launcher; print("ipykernel", ipykernel.__version__)' >&2
echo "DRGNX_NB_KERNEL_PYTHON=$dir/venv/bin/python3"

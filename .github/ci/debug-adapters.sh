#!/usr/bin/env bash
# The debug adapters the live debug tests run against, at the hub's pins (etc/debug-adapters.eld) and checked as
# `Debug: Install Adapter` checks them: debugpy as a hash-pinned wheel in a venv, js-debug as the DAP release tarball with
# its sha256 verified.  Prints the two variables the live tests read (`debug::tests_fork_live`, `tests_blocked_live`,
# `tests_live_adapters`) as NAME=VALUE lines, for `>> "$GITHUB_ENV"`.
# DRGNX_ADAPTER_PYTHON (default python3, which must be 3.10 or later) makes the venv: the macOS row names Homebrew's
# /opt/homebrew/bin/python3 (3.10+, and under a root the Seatbelt profile of a fork execs), because the profile refuses
# to exec a python that lives in the runner's tool cache
# ("sandbox-exec: execvp() of '.../tools/venv/bin/python3' failed: Operation not permitted") and /usr/bin/python3 is 3.9.
# Usage: debug-adapters.sh DIR
set -euo pipefail
dir=${1:?usage: debug-adapters.sh DIR}
py=${DRGNX_ADAPTER_PYTHON:-python3}
# debugpy's wheels say Python >= 3.10: below it pip answers "No matching distribution" (macOS's /usr/bin/python3 is 3.9)
"$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
  || { echo "debug-adapters.sh: $py is not Python 3.10 or later: debugpy needs Python 3.10+ (set DRGNX_ADAPTER_PYTHON)" >&2; exit 1; }
mkdir -p "$dir"
"$py" -m venv "$dir/venv"
printf 'debugpy==1.8.22 --hash=sha256:a9e9d3550e15ca479c59333e90845029190531f0cacfedab3b815a57bd913947\n' > "$dir/req.txt"
"$dir/venv/bin/pip" install --quiet --require-hashes -r "$dir/req.txt" >&2
curl -sSfL -o "$dir/js.tgz" https://github.com/microsoft/vscode-js-debug/releases/download/v1.140.1/js-debug-dap-v1.140.1.tar.gz
sum="c72fab31bcbfdce6ad1f42adfd28eff8d4681dd3b03b5e2e6f9e72e6f9927faf  $dir/js.tgz"
if command -v sha256sum >/dev/null; then echo "$sum" | sha256sum -c - >&2; else echo "$sum" | shasum -a 256 -c - >&2; fi
tar -xzf "$dir/js.tgz" -C "$dir"
test -f "$dir/js-debug/src/dapDebugServer.js"
echo "DRGNX_DEBUG_LIVE_PYTHON=$dir/venv/bin/python3"
echo "DRGNX_DEBUG_LIVE_JS_DEBUG=$dir/js-debug/src/dapDebugServer.js"

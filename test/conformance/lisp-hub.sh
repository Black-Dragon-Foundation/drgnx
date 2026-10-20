#!/usr/bin/env bash
# The Lisp hub behind the conformance harness's interface (docs/develop/runtime.md): the harness starts a hub as
# `BIN serve --foreground --parent-pid PID`; this maps that to the Lisp hub process.  With no arguments (as
# Ratatoskr's DRGNX_RATATOSKR_BACKEND) it starts the same Emacs command with the environment as given.
# Emacs is $DRGNX_EMACS (else `emacs` on PATH).  Any other argv is refused with exit 2.
set -euo pipefail

drgnx=$(cd "$(dirname "$0")/../.." && pwd)
emacs=${DRGNX_EMACS:-emacs}

hub() {
  exec "$emacs" --batch -Q --eval '(setq load-prefer-newer t)' -L "$drgnx/core" -l drgnx-hub -f drgnx-hub-main
}

if [ "$#" -eq 0 ]; then
  hub
elif [ "$#" -eq 4 ] && [ "$1" = serve ] && [ "$2" = --foreground ] && [ "$3" = --parent-pid ]; then
  case $4 in
    '' | *[!0-9]*) echo "lisp-hub.sh: --parent-pid takes a pid" >&2; exit 2 ;;
  esac
  export DRGNX_HUB_PARENT_PID=$4
  hub
else
  echo "lisp-hub.sh: usage: lisp-hub.sh [serve --foreground --parent-pid PID]" >&2
  exit 2
fi

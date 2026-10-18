#!/bin/sh
# mock-acp-stdin.sh CMD [ARG...] -- run CMD (batch Emacs loading mock-acp.el) with MOCK_ACP_IN naming a FIFO that
# carries this process's stdin.  Batch Emacs cannot read its stdin while its timers run, so the mock reads it with
# a cat process: of /proc/PID/fd/0 on Linux only, of this FIFO on every POSIX system (macOS).
# A mock killed with its whole process group before it opened its FIFO (tests that stop agents at once) kills the
# watcher below too, so nothing removes its directory then: swept here a minute on.  No process is left either way.
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'mock-acp.*' -user "$(id -u)" -mmin +1 -exec rm -rf {} + 2>/dev/null
d=$(mktemp -d "${TMPDIR:-/tmp}/mock-acp.XXXXXX") || exit 1
mkfifo "$d/in" || { rmdir "$d"; exit 1; }
exec 3<&0
# The copier (fd 3: an asynchronous list's stdin is /dev/null).  Opening the FIFO waits for the mock's reader;
# then both ends are open and the name goes.  EOF on stdin closes the FIFO, which ends the mock.  Of the caller's
# pipes it holds stdin only, never stdout or stderr: a reader waiting for their EOF never waits on it.
(exec >"$d/in" && rm -rf "$d" && exec cat <&3) >/dev/null 2>&1 &
c=$!
# The watcher: once the mock (this pid, after the exec below) is gone, so are the copier, even one still waiting
# for a reader, and the FIFO.  It holds none of the caller's pipes.
(while kill -0 $$ 2>/dev/null; do sleep 1; done; kill $c 2>/dev/null; rm -rf "$d") </dev/null >/dev/null 2>&1 3<&- &
exec 3<&-
MOCK_ACP_IN=$d/in
export MOCK_ACP_IN
exec "$@"

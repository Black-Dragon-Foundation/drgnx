# Sourced by make-secrets.sh and in-container.sh (bash): run a program that asks on its terminal (sudo's password, age's
# passphrase, a y-or-n question) on a real pseudo-terminal, and type the answers when the prompts appear.
#
#   pty_run LOG COMMAND [MARKER REPLY]…
#
# COMMAND (a shell string) runs under util-linux `script`, so it has a controlling terminal like a user's shell has.
# LOG receives everything the terminal showed (a typed secret must never be in it: a prompt that does not switch the
# echo off would show it).  The pairs are prompts in the order they come: REPLY and a newline are typed when MARKER
# shows up after the prompt answered before it (text printed earlier, a question that mentions a passphrase, never
# counts).  Each wait is bounded: no next prompt (or, after the last, no end) within PTY_STEP_TIMEOUT seconds (300)
# stops the command and its terminal.  Sets PTY_RC to COMMAND's exit status, and PTY_STUCK to what it was waiting for
# when it was stopped (PTY_RC is then 124), or to the prompt it never saw when the command ended first (empty: all
# answered).  The caller prints LOG either way: it is the screen.
pty_run() {
  local log=$1 cmd=$2; shift 2
  local -a pairs=("$@")
  local bound=${PTY_STEP_TIMEOUT:-300} dir pid fd i pos=0 at t0 want stopped=""
  dir=$(mktemp -d)
  mkfifo "$dir/in"
  : >"$log"
  exec {fd}<>"$dir/in"   # read-write: opening never blocks, and the fifo has a writer for as long as this runs
  script -qf -c "$cmd; echo PTY-DONE \$?" "$log" <"$dir/in" >/dev/null 2>&1 &
  pid=$!
  PTY_STUCK=""
  done_() { grep -aq 'PTY-DONE [0-9]' "$log" || ! kill -0 "$pid" 2>/dev/null; }
  for ((i = 0; i <= ${#pairs[@]}; i += 2)); do
    if ((i < ${#pairs[@]})); then want="the prompt '${pairs[i]}'"; else want="the end of the command"; fi
    t0=$SECONDS
    while :; do
      if ((i < ${#pairs[@]})); then
        # the byte offset of the first MARKER after the prompt answered last
        at=$(grep -aboF -- "${pairs[i]}" "$log" | awk -F: -v p="$pos" '$1 + 0 >= p {print $1; exit}') || true
        [[ -z "$at" ]] || break
        if done_; then PTY_STUCK="${pairs[i]} (the command ended first)"; break 2; fi
      elif done_; then break 2; fi
      if ((SECONDS - t0 >= bound)); then
        PTY_STUCK="$want: not within ${bound} s"
        echo "pty_run: waited $bound s for $want: stopping the command" >&2
        stopped=1
        kill -TERM "$pid" 2>/dev/null || true   # script passes it to the command; the terminal's hangup ends what runs on it
        break 2
      fi
      sleep 0.3
    done
    pos=$((at + ${#pairs[i]}))
    sleep 0.4   # the program is reading (and has switched the echo off) by now
    printf '%s\n' "${pairs[i + 1]}" >&"$fd"
  done
  for ((i = 0; i < 50; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  exec {fd}>&-
  rm -rf "$dir"
  unset -f done_
  PTY_RC=$(grep -a 'PTY-DONE [0-9]' "$log" | tail -1 | tr -d '\r' | awk '{print $2}' || true)
  [[ -z "$stopped" ]] || PTY_RC=124
  PTY_RC=${PTY_RC:-1127}
}

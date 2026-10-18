# Sourced by make-secrets.sh and in-container.sh (bash): run a program that asks on its terminal (sudo's password, age's
# passphrase, a y-or-n question) on a real pseudo-terminal, and type the answers when the prompts appear.
#
#   pty_run LOG COMMAND [MARKER REPLY]…
#
# COMMAND (a shell string) runs under util-linux `script`, so it has a controlling terminal like a user's shell has.
# LOG receives everything the terminal showed (a typed secret must never be in it: a prompt that does not switch the
# echo off would show it).  When MARKER appears in LOG, REPLY and a newline are typed; the pairs are used in order and
# a marker that comes up twice is waited for twice.  Sets PTY_RC to COMMAND's exit status (127 + 1000 when it never ended).
pty_run() {
  local log=$1 cmd=$2; shift 2
  local -a pairs=("$@")
  : >"$log"
  {
    local i j want n t0
    for ((i = 0; i < ${#pairs[@]}; i += 2)); do
      want=1
      for ((j = 0; j < i; j += 2)); do [[ ${pairs[j]} == "${pairs[i]}" ]] && want=$((want + 1)); done
      t0=$SECONDS
      while :; do
        n=$(grep -aoF -- "${pairs[i]}" "$log" | wc -l)
        if ((n >= want)); then break; fi
        if grep -aq 'PTY-DONE [0-9]' "$log"; then break; fi     # the command ended before this prompt: the caller's checks say so
        if ((SECONDS - t0 > 900)); then echo "pty_run: no '${pairs[i]}' in 15 minutes" >&2; break; fi
        sleep 0.3
      done
      sleep 0.4   # the program is reading (and has switched the echo off) by now
      printf '%s\n' "${pairs[i + 1]}"
    done
    t0=$SECONDS
    until grep -aq 'PTY-DONE [0-9]' "$log"; do
      if ((SECONDS - t0 > 1800)); then break; fi
      sleep 0.3
    done
  } | script -qf -c "$cmd; echo PTY-DONE \$?" "$log" >/dev/null || true
  PTY_RC=$(grep -a 'PTY-DONE [0-9]' "$log" | tail -1 | tr -d '\r' | awk '{print $2}')
  PTY_RC=${PTY_RC:-1127}
}

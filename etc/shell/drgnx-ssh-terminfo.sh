# drgnx-ssh-terminfo.sh SCRIPT SSH-ARGS...: the program of a terminal in a remote folder with drgnx-term-ssh-terminfo
# `install' (run by /bin/sh in the terminal's PTY, so a password prompt of either ssh shows there).  The first time
# for a host it sends Ghostty's terminfo entry to the host's tic (into the remote ~/.terminfo) and records the outcome
# in <state>/terminal-ssh-hosts, one "USER@HOST:PORT TERM" line per host, the file drgnx's shell file keeps for an ssh
# typed in a terminal (delete a line to try again); then it runs `ssh -t SSH-ARGS... SCRIPT' with that TERM.
# SSH-ARGS are ssh's options and the destination.  POSIX sh.  docs/develop/terminal.md, "Remote terminals".
script=$1
shift
case ${XDG_STATE_HOME-} in
  /*) rec=$XDG_STATE_HOME/drgnx/terminal-ssh-hosts ;;
  *) rec=$HOME/.local/state/drgnx/terminal-ssh-hosts ;;
esac
key=$(ssh -G "$@" 2>/dev/null | awk '$1 == "user" { u = $2 } $1 == "hostname" { h = $2 } $1 == "port" { p = $2 }
  END { if (h != "") print u "@" h ":" p }')
term=
if [ -n "$key" ] && [ -r "$rec" ]; then
  term=$(awk -v k="$key" '$1 == k { t = $2 } END { print t }' "$rec")
fi
if [ -z "$term" ]; then
  term=xterm-256color
  if infocmp -x xterm-ghostty 2>/dev/null | TERM=xterm-256color ssh "$@" 'tic -x -'; then
    term=xterm-ghostty
  fi
  [ -z "$key" ] || { mkdir -p "${rec%/*}" && printf '%s %s\n' "$key" "$term" >> "$rec"; }
fi
TERM=$term exec ssh -t "$@" "$script"

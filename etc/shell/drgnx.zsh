# drgnx shell integration for zsh.  Add one line to ~/.zshrc:   source /path/to/drgnx/etc/shell/drgnx.zsh
# (docs/guide/shell.md).  It prints nothing, runs no program while it loads, and outside drgnx's own terminal never
# touches PROMPT, PS1 or your plugin manager.  What it does: tab completion for drgnx; inside drgnx's own terminal,
# Ghostty's shell integration (prompt marks, the folder, the title; it adds to PS1 and the hooks) and an ssh that
# gives the host a TERM it knows; inside eat, eat's shell integration.
(( ${+_drgnx_sourced} )) && return 0
typeset -g _drgnx_sourced=1

# Completion: the directory of this file holds _drgnx.  With compinit already run, register it now; otherwise
# compinit finds it through fpath when it runs.
fpath=("${${(%):-%x}:A:h}" "${fpath[@]}")
if (( ${+functions[compdef]} )); then
  autoload -Uz _drgnx
  compdef _drgnx drgnx
fi

# Inside eat only: its integration file is what makes a prompt clear "a program is running".  Eat refuses to
# enable itself twice, so a line of your own that sources it is harmless.  It hands Emacs your history with
# tail on $HISTFILE: without a readable HISTFILE (zsh sets none by default) that would print an error at every start,
# so it then sees /dev/null instead, for the moment it is sourced; your HISTFILE stays as it was.
if [[ ${INSIDE_EMACS-} == *eat* && -n ${EAT_SHELL_INTEGRATION_DIR-} && -r ${EAT_SHELL_INTEGRATION_DIR-}/zsh ]]; then
  if [[ -r ${HISTFILE-} ]]; then
    source "$EAT_SHELL_INTEGRATION_DIR/zsh"
  else
    _drgnx_eat() { local HISTFILE=/dev/null; source "$EAT_SHELL_INTEGRATION_DIR/zsh"; }
    _drgnx_eat; unfunction _drgnx_eat
  fi
fi

# Inside drgnx's own terminal (DRGNX_TERMINAL, set by drgnx-term.el).  Ghostty's shell integration, vendored in
# ghostty/ next to this file (ghostty/NOTICE): prompt and command marks, the folder, the title, a sudo that keeps
# TERMINFO.  Its features are the terminal's GHOSTTY_SHELL_FEATURES (drgnx-term-shell-integration-features; unset: the
# integration is off) without Ghostty's ssh ones, which need Ghostty's own program: drgnx's ssh is below.
# DRGNX_TERMINAL_SHELL, when set, names the one shell that loads it.
if [[ -n ${DRGNX_TERMINAL-} ]]; then
  () {
    emulate -L zsh
    [[ -n ${GHOSTTY_SHELL_FEATURES+x} && ${DRGNX_TERMINAL_SHELL:-zsh} == zsh ]] || return 1
    [[ -r $1/ghostty/shell-integration/zsh/ghostty-integration ]] || return 1
    local f
    local -a keep
    for f in ${(s:,:)GHOSTTY_SHELL_FEATURES}; do [[ $f == ssh-* ]] || keep+=($f); done
    export GHOSTTY_RESOURCES_DIR=$1/ghostty GHOSTTY_SHELL_FEATURES=${(j:,:)keep}
    unset GHOSTTY_BIN_DIR
  } "${${(%):-%x}:A:h}" && source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"

  # ssh from drgnx's terminal (TERM=xterm-ghostty): a host knows that entry only once it is installed there.  fallback
  # (DRGNX_TERMINAL_SSH, from drgnx-term-ssh-terminfo): ssh says TERM=xterm-256color.  install: the first ssh to a
  # host sends the entry to its tic (into the remote ~/.terminfo) and records the outcome in
  # <state>/terminal-ssh-hosts, one "USER@HOST:PORT TERM" line per host (delete a line to try again).
  function ssh {
    emulate -L zsh
    if [[ ${TERM-} != xterm-ghostty ]]; then command ssh "$@"; return; fi
    typeset -g _drgnx_term=xterm-256color
    if [[ ${DRGNX_TERMINAL_SSH-fallback} == install ]]; then _drgnx_ssh_terminfo "$@"; fi
    TERM=$_drgnx_term command ssh "$@"
  }
  function _drgnx_ssh_terminfo { # sets _drgnx_term for this ssh's host
    emulate -L zsh
    local k v user= host= port= key rec=$HOME/.local/state/drgnx/terminal-ssh-hosts
    [[ ${XDG_STATE_HOME-} == /* ]] && rec=$XDG_STATE_HOME/drgnx/terminal-ssh-hosts
    while read -r k v; do
      case $k in (user) user=$v ;; (hostname) host=$v ;; (port) port=$v ;; esac
    done < <(command ssh -G "$@" 2>/dev/null)
    [[ -n $host ]] || return 0
    key=$user@$host:$port
    if [[ -r $rec ]]; then
      while read -r k v; do
        if [[ $k == "$key" ]]; then _drgnx_term=$v; return 0; fi
      done < "$rec"
    fi
    local -a opts
    local dest= a
    while (( $# )); do   # the options, then the destination: the host's tic runs instead of any command of yours
      a=$1; shift
      case $a in
        (--) dest=${1-}; break ;;
        (-[BbcDEeFIiJLlmOoPpQRSWw]) opts+=("$a" "${1-}"); (( $# )) && shift ;;
        (-*) opts+=("$a") ;;
        (*) dest=$a; break ;;
      esac
    done
    [[ -n $dest ]] || return 0
    if command infocmp -x xterm-ghostty 2>/dev/null |
        TERM=xterm-256color command ssh "${opts[@]}" -- "$dest" 'tic -x -'; then
      _drgnx_term=xterm-ghostty
    fi
    command mkdir -p "${rec:h}" && print -r -- "$key $_drgnx_term" >> "$rec"
  }
fi

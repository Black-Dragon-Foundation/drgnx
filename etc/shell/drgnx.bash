# drgnx shell integration for bash.  Add one line to ~/.bashrc:   source /path/to/drgnx/etc/shell/drgnx.bash
# (docs/guide/shell.md).  It prints nothing, runs no program while it loads, and outside drgnx's own terminal never
# touches PS1, PROMPT_COMMAND or your plugin manager.  What it does: tab completion for drgnx; inside drgnx's own
# terminal, Ghostty's shell integration (prompt marks, the folder, the title; it adds to PS1 and PROMPT_COMMAND) and an
# ssh that gives the host a TERM it knows.
[[ -n ${_drgnx_sourced-} ]] && return 0
_drgnx_sourced=1

# Completion: drgnx's commands and their options, then file names.  Static lists, kept honest by a test that reads
# bin/drgnx (test/unit/shell-completion-test.el); only --keys looks at the disk (a glob of keys/*.eld at TAB time).
case ${BASH_SOURCE[0]-} in
  /*) _drgnx_dir=${BASH_SOURCE[0]%/*} ;;
  */*) _drgnx_dir=$PWD/${BASH_SOURCE[0]%/*} ;;
  *) _drgnx_dir=$PWD ;;
esac
_drgnx_commands='open doctor build test ui macos-app sync upgrade rollback generations lock bisect service-unit onboard check lease fmt work hub runtime job runner search keys safe help shell secrets bootstrap update coord graph childframe-elpa browser plugins extensions record replay'
_drgnx_steps='environment look-and-keys projects ai search agents daemon portability finish'
_drgnx_bootstrap_steps='preflight config keys sync onboard desktop shell doctor'
_drgnx_presets='minimal ide full-ai'
_drgnx_uis='start frame stop ls reap state shot click keys type measure mcp test-ui test-ui-session'
_drgnx_installs='debian-trixie ubuntu-26.04 fedora-45 archlinux'

_drgnx() {
  local n=${COMP_CWORD-0} cur=${COMP_WORDS[${COMP_CWORD-0}]-} prev= cmd= sub= words= w f i
  COMPREPLY=()
  if [[ $n -gt 0 ]]; then prev=${COMP_WORDS[n-1]-}; fi
  if [[ $n -ge 2 ]]; then cmd=${COMP_WORDS[1]-}; fi
  if [[ $n -ge 3 ]]; then sub=${COMP_WORDS[2]-}; fi

  if [[ $n -le 1 ]]; then   # the command, or a file or folder to open
    if [[ $cur == -* ]]; then
      words='-h --help -t --gui'
    else
      words=$_drgnx_commands
      for f in "$cur"*; do
        if [[ -e $f ]]; then
          if [[ -d $f ]]; then f=$f/; fi
          COMPREPLY+=("$f")
        fi
      done
    fi
  else
    case $prev in   # the value of an option
      --step) if [[ $cmd == onboard ]]; then words=$_drgnx_steps; elif [[ $cmd == bootstrap ]]; then words=$_drgnx_bootstrap_steps; fi ;;
      --preset) if [[ $cmd == onboard ]]; then words=$_drgnx_presets; fi ;;
      --shell) if [[ $cmd == shell ]]; then words='zsh bash fish'; fi ;;
      --fedora) if [[ $cmd == test ]]; then words='44 45'; fi ;;
      --compositor) if [[ $cmd == test ]]; then words='mutter sway x11 i3 kwin niri'; fi ;;
      --auto) if [[ $cmd == update ]]; then words='on off status'; fi ;;
      --config) if [[ $cmd == test ]]; then words='drgnx gryphn'; elif [[ $cmd == ui ]]; then words='minimal drgnx gryphn'; fi ;;
      --keys)
        if [[ $cmd == onboard ]]; then
          for f in "$_drgnx_dir"/../../keys/*.eld; do
            if [[ -e $f ]]; then
              f=${f##*/}
              words+=" ${f%.eld}"
            fi
          done
        fi ;;
    esac
    if [[ -z $words ]]; then
      if [[ $cur == -* ]]; then
        case "$cmd $sub" in
          'open '*) words='--check --wait -t --gui' ;;
          'doctor '*) words='--json --dev' ;;
          'test '*) words='--one-process --leaks --shuffle --find-polluter --stress --load --ui --compositor --tty --scenario --config --bench --perf --audit --ab --ab-env --n --aa --no-aa --soak --day --preflight --out --seeds --nidhogg-tarball --container --install --bootstrap --fedora' ;;
          'sync '*) words='--offline --seed --prune --dry-run --add --remove --pending --wait --progress' ;;
          'upgrade '*) words='--only --stage --staged --progress' ;;
          'rollback '*) words='--progress' ;;
          'extensions '*) words='--progress' ;;
          'record start') words='--cap-usd --cap-weekly --max-minutes' ;;
          'record export') words='--to' ;;
          'replay '*) words='--speed --strict' ;;
          'lock '*) words='--ship' ;;
          'onboard '*) words='--non-interactive --again --preset --keys --theme --roots --todos --step' ;;
          'check '*) words='--no-perf --no-gui --jobs --shards' ;;
          'lease '*) words='--wait' ;;
          'fmt '*) words='--check' ;;
          'work record') words='--task' ;;
          'work scan') words='--board' ;;
          'work status') words='--json' ;;
          'hub '*) words='--json' ;;
          'runtime build') words='--install --prefix' ;;
          'runtime install') words='--prefix' ;;
          'browser install') words='--version --json' ;;
          'browser list') words='--json' ;;
          'job propose') words='--repo --budget --auto' ;;
          'job approve' | 'job resume') words='--budget' ;;
          'job status') words='--json' ;;
          'runner list') words='--json' ;;
          'runner add') words='--trust --name --profile --accept --root --prefix' ;;
          'runner remove') words='--yes' ;;
          'search index') words='--rebuild --now' ;;
          'search query') words='-k --scope' ;;
          'build runner-bundle') words='--arch --target' ;;
          'keys diff') words='--against' ;;
          'ui start') words='--config --size --daemon' ;;
          'ui click') words='--buffer --text --button --count --hold-ms' ;;
          'shell install') words='--shell --yes' ;;
          'shell line') words='--shell' ;;
          'secrets export') words='--recipient' ;;
          'secrets import') words='--identity --replace' ;;
          'plugins install') words='--replace' ;;
          'plugins list') words='--json' ;;
          'secrets ls') words='--identity' ;;
          'bootstrap '*) words='--config --chezmoi --identity --step --dry-run --yes --replace' ;;
          'update '*) words='--quiet --back --restart --auto' ;;
          'coord mcp') words='--kind' ;;
        esac
      elif [[ $n -eq 2 ]]; then   # the word after the command
        case $cmd in
          work) words='record scan status' ;;
          hub) words='start stop status' ;;
          build) words='runner-bundle terminfo' ;;
          runtime) words='build install' ;;
          browser) words='install list' ;;
          plugins) words='install list remove' ;;
          job) words='propose approve resume stop status' ;;
          runner) words='list add check bench trust unbench remove audit' ;;
          search) words='index query mcp' ;;
          keys) words='diff' ;;
          ui) words=$_drgnx_uis ;;
          shell) words='install line' ;;
          secrets) words='export import ls' ;;
          coord) words='mcp' ;;
          graph) words='export import backup revert excise scrub grants sql compact proposed' ;;
          service-unit) words='--refresh' ;;
        esac
      elif [[ $cmd == test ]]; then   # test --install NAME…
        for ((i = 2; i < n; i++)); do
          if [[ ${COMP_WORDS[i]-} == --install ]]; then words=$_drgnx_installs; fi
        done
      fi
    fi
  fi
  for w in $words; do
    if [[ $w == "$cur"* ]]; then COMPREPLY+=("$w"); fi
  done
  return 0
}
complete -o default -o filenames -F _drgnx drgnx

# Inside drgnx's own terminal (DRGNX_TERMINAL, set by drgnx-term.el).  Ghostty's shell integration, vendored in
# ghostty/ next to this file (ghostty/NOTICE): prompt and command marks, the folder, the title, a sudo that keeps
# TERMINFO.  Its features are the terminal's GHOSTTY_SHELL_FEATURES (drgnx-term-shell-integration-features; unset: the
# integration is off) without Ghostty's ssh ones, which need Ghostty's own program: drgnx's ssh is below.
# DRGNX_TERMINAL_SHELL, when set, names the one shell that loads it.
_drgnx_ghostty_features() { # GHOSTTY_SHELL_FEATURES without ssh-*
  local IFS=, f out=
  for f in $GHOSTTY_SHELL_FEATURES; do
    case $f in ssh-*) ;; *) out=${out:+$out,}$f ;; esac
  done
  GHOSTTY_SHELL_FEATURES=$out
}
if [[ -n ${DRGNX_TERMINAL-} && -n ${GHOSTTY_SHELL_FEATURES+x} && ${DRGNX_TERMINAL_SHELL:-bash} == bash
      && -r $_drgnx_dir/ghostty/shell-integration/bash/ghostty.bash ]]; then
  _drgnx_ghostty_features
  export GHOSTTY_RESOURCES_DIR=$_drgnx_dir/ghostty GHOSTTY_SHELL_FEATURES
  unset GHOSTTY_BIN_DIR
  case $- in   # Ghostty's file reads unset variables as empty: not under set -u
    *u*) set +u; builtin source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash"; set -u ;;
    *) builtin source "$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash" ;;
  esac
fi
unset -f _drgnx_ghostty_features

# ssh from drgnx's terminal (TERM=xterm-ghostty): a host knows that entry only once it is installed there.  fallback
# (DRGNX_TERMINAL_SSH, from drgnx-term-ssh-terminfo): ssh says TERM=xterm-256color.  install: the first ssh to a host
# sends the entry to its tic (into the remote ~/.terminfo) and records the outcome in <state>/terminal-ssh-hosts, one
# "USER@HOST:PORT TERM" line per host (delete a line to try again); later ones use what is recorded.
if [[ -n ${DRGNX_TERMINAL-} ]]; then
  function ssh {
    if [[ ${TERM-} != xterm-ghostty ]]; then command ssh "$@"; return; fi
    _drgnx_term=xterm-256color
    if [[ ${DRGNX_TERMINAL_SSH-fallback} == install ]]; then _drgnx_ssh_terminfo "$@"; fi
    TERM=$_drgnx_term command ssh "$@"
  }
  function _drgnx_ssh_terminfo { # sets _drgnx_term for this ssh's host
    local k v user= host= port= key rec=$HOME/.local/state/drgnx/terminal-ssh-hosts
    [[ ${XDG_STATE_HOME-} == /* ]] && rec=$XDG_STATE_HOME/drgnx/terminal-ssh-hosts
    while read -r k v; do
      case $k in user) user=$v ;; hostname) host=$v ;; port) port=$v ;; esac
    done < <(command ssh -G "$@" 2>/dev/null)
    [[ -n $host ]] || return 0
    key=$user@$host:$port
    if [[ -r $rec ]]; then
      while read -r k v; do
        if [[ $k == "$key" ]]; then _drgnx_term=$v; return 0; fi
      done < "$rec"
    fi
    local -a opts=()
    local dest= a
    while (($#)); do   # the options, then the destination: the host's tic runs instead of any command of yours
      a=$1; shift
      case $a in
        --) dest=${1-}; break ;;
        -[BbcDEeFIiJLlmOoPpQRSWw]) opts+=("$a" "${1-}"); (($#)) && shift ;;
        -*) opts+=("$a") ;;
        *) dest=$a; break ;;
      esac
    done
    [[ -n $dest ]] || return 0
    if command infocmp -x xterm-ghostty 2>/dev/null |
        TERM=xterm-256color command ssh ${opts[@]+"${opts[@]}"} -- "$dest" 'tic -x -'; then
      _drgnx_term=xterm-ghostty
    fi
    command mkdir -p "${rec%/*}" && printf '%s %s\n' "$key" "$_drgnx_term" >> "$rec"
  }
fi

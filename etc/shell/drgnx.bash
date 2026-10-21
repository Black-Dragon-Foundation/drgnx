# drgnx shell integration for bash.  Add one line to ~/.bashrc:   source /path/to/drgnx/etc/shell/drgnx.bash
# (docs/guide/shell.md).  It prints nothing, runs no program while it loads, and never touches PS1, PROMPT_COMMAND
# or your plugin manager.  What it does: tab completion for drgnx, and inside drgnx's own terminal (eat) eat's shell
# integration (directory tracking, prompt marks, "is a command running").
[[ -n ${_drgnx_sourced-} ]] && return 0
_drgnx_sourced=1

# Completion: drgnx's commands and their options, then file names.  Static lists, kept honest by a test that reads
# bin/drgnx (test/unit/shell-completion-test.el); only --keys looks at the disk (a glob of keys/*.eld at TAB time).
case ${BASH_SOURCE[0]-} in
  /*) _drgnx_dir=${BASH_SOURCE[0]%/*} ;;
  */*) _drgnx_dir=$PWD/${BASH_SOURCE[0]%/*} ;;
  *) _drgnx_dir=$PWD ;;
esac
_drgnx_commands='open doctor build test ui macos-app sync upgrade rollback generations lock bisect service-unit onboard check lease fmt work hub runtime job search keys safe help shell secrets bootstrap update coord'
_drgnx_steps='environment look-and-keys projects ai search agents daemon portability finish'
_drgnx_bootstrap_steps='preflight config keys sync onboard desktop shell doctor'
_drgnx_presets='minimal ide full-ai'
_drgnx_uis='start frame stop ls reap state shot click keys type measure mcp test-ui test-ui-session'
_drgnx_installs='fedora-44 debian-trixie ubuntu-26.04 fedora-45 archlinux'

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
          'test '*) words='--one-process --leaks --shuffle --find-polluter --stress --load --ui --compositor --tty --scenario --config --bench --perf --audit --ab --n --soak --container --install --bootstrap --fedora' ;;
          'sync '*) words='--offline --seed --prune --dry-run' ;;
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
          'job propose') words='--repo --budget --auto' ;;
          'job approve' | 'job resume') words='--budget' ;;
          'job status') words='--json' ;;
          'search index') words='--rebuild' ;;
          'search query') words='-k' ;;
          'keys diff') words='--against' ;;
          'ui start') words='--config --size --daemon' ;;
          'ui click') words='--buffer --text --button --count --hold-ms' ;;
          'shell install') words='--shell --yes' ;;
          'shell line') words='--shell' ;;
          'secrets export') words='--recipient' ;;
          'secrets import') words='--identity --replace' ;;
          'secrets ls') words='--identity' ;;
          'bootstrap '*) words='--config --chezmoi --identity --step --dry-run --yes --replace' ;;
          'update '*) words='--quiet --back --restart --auto' ;;
          'coord mcp') words='--kind' ;;
        esac
      elif [[ $n -eq 2 ]]; then   # the word after the command
        case $cmd in
          work) words='record scan status' ;;
          hub) words='start stop status' ;;
          runtime) words='build install' ;;
          job) words='propose approve resume stop status' ;;
          search) words='index query mcp' ;;
          keys) words='diff' ;;
          ui) words=$_drgnx_uis ;;
          shell) words='install line' ;;
          secrets) words='export import ls' ;;
          coord) words='mcp' ;;
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

# Inside eat only: its integration file is what makes a prompt clear "a program is running".  Eat refuses to
# enable itself twice, so a line of your own that sources it is harmless.  It hands Emacs your history with
# tail on $HISTFILE: without a readable HISTFILE (none written yet) that would print an error at every start, so it
# then sees /dev/null instead, for the moment it is sourced; your HISTFILE stays as it was.
if [[ ${INSIDE_EMACS-} == *eat* && -n ${EAT_SHELL_INTEGRATION_DIR-} && -r ${EAT_SHELL_INTEGRATION_DIR-}/bash ]]; then
  if [[ -r ${HISTFILE-} ]]; then
    source "$EAT_SHELL_INTEGRATION_DIR/bash"
  else
    _drgnx_eat() { local HISTFILE=/dev/null; source "$EAT_SHELL_INTEGRATION_DIR/bash"; }
    _drgnx_eat; unset -f _drgnx_eat
  fi
fi

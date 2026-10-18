# drgnx shell integration for zsh.  Add one line to ~/.zshrc:   source /path/to/drgnx/etc/shell/drgnx.zsh
# (docs/guide/shell.md).  It prints nothing, runs no program while it loads, and never touches PROMPT, PS1 or your
# plugin manager.  What it does: tab completion for drgnx, and inside drgnx's own terminal (eat) eat's shell
# integration (directory tracking, prompt marks, "is a command running").
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
# enable itself twice, so a line of your own that sources it is harmless.
if [[ ${INSIDE_EMACS-} == *eat* && -n ${EAT_SHELL_INTEGRATION_DIR-} && -r ${EAT_SHELL_INTEGRATION_DIR-}/zsh ]]; then
  source "$EAT_SHELL_INTEGRATION_DIR/zsh"
fi

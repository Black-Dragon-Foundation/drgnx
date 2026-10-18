# drgnx shell integration for bash.  Add one line to ~/.bashrc:   source /path/to/drgnx/etc/shell/drgnx.bash
# (docs/guide/shell.md).  It prints nothing, runs no program while it loads, and never touches PS1, PROMPT_COMMAND
# or your plugin manager.  What it does: tab completion for drgnx, and inside drgnx's own terminal (eat) eat's shell
# integration (directory tracking, prompt marks, "is a command running").
[[ -n ${_drgnx_sourced-} ]] && return 0
_drgnx_sourced=1

# Completion: drgnx's commands, then file names.
_drgnx() {
  COMPREPLY=()
}
complete -o default -F _drgnx drgnx

# Inside eat only: its integration file is what makes a prompt clear "a program is running".  Eat refuses to
# enable itself twice, so a line of your own that sources it is harmless.
if [[ ${INSIDE_EMACS-} == *eat* && -n ${EAT_SHELL_INTEGRATION_DIR-} && -r ${EAT_SHELL_INTEGRATION_DIR-}/bash ]]; then
  source "$EAT_SHELL_INTEGRATION_DIR/bash"
fi

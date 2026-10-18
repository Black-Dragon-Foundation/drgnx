# drgnx shell integration for fish.  Add one line to ~/.config/fish/config.fish:
#   source /path/to/drgnx/etc/shell/drgnx.fish
# (docs/guide/shell.md).  It prints nothing, runs no program while it loads, and never touches fish_prompt or your
# plugin manager.  What it does: tab completion for drgnx, and inside drgnx's own terminal (eat) the few lines of
# eat's integration that fish needs (eat ships none for fish): directory tracking and "is a command running".
if not set -q _drgnx_sourced
    set -g _drgnx_sourced 1

    # Completion: drgnx's options, then file names.
    complete -c drgnx -s h -l help -d 'Show drgnx usage'

    # Inside eat only.  The prompt-end mark is bash and zsh only: fish cannot add it without redefining fish_prompt.
    if string match -q '*eat*' -- "$INSIDE_EMACS"; and set -q EAT_SHELL_INTEGRATION_DIR
        function __drgnx_eat_preexec --on-event fish_preexec
            set -g __drgnx_eat_ran 1
            printf '\e]51;e;F;%s\e\\\\' (printf %s $argv[1] | base64 | string join '')
            printf '\e]51;e;G\e\\\\'
        end

        function __drgnx_eat_prompt --on-event fish_prompt
            set -l last $status
            if set -q __drgnx_eat_ran
                set -e __drgnx_eat_ran
                printf '\e]51;e;H;%s\e\\\\' $last
            end
            printf '\e]51;e;A;%s;%s\e\\\\' (printf %s $hostname | base64 | string join '') (printf %s $PWD | base64 | string join '')
            printf '\e]51;e;B\e\\\\'
        end
    end
end

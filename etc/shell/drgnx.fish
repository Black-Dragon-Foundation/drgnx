# drgnx shell integration for fish.  Add one line to ~/.config/fish/config.fish:
#   source /path/to/drgnx/etc/shell/drgnx.fish
# (docs/guide/shell.md).  It prints nothing, runs no program while it loads, and never touches fish_prompt or your
# plugin manager.  What it does: tab completion for drgnx, and inside drgnx's own terminal (eat) the few lines of
# eat's integration that fish needs (eat ships none for fish): directory tracking and "is a command running".
if not set -q _drgnx_sourced
    set -g _drgnx_sourced 1

    # Completion: drgnx's commands and their options, then file names.  Static lists, kept honest by a test that
    # reads bin/drgnx (test/unit/shell-completion-test.el); only --keys looks at the disk (a glob of keys/*.eld at TAB
    # time, relative to this file).
    status filename | string replace -r '/[^/]*$' '' | read -g __drgnx_dir
    if not string match -q '/*' -- "$__drgnx_dir"
        set -g __drgnx_dir "$PWD/$__drgnx_dir"
    end

    function __drgnx_keys
        for f in $__drgnx_dir/../../keys/*.eld
            string replace -r '.*/([^/]*)\.eld$' '$1' -- $f
        end
    end

    complete -c drgnx -n __fish_use_subcommand -s h -l help -d 'Show drgnx usage'
    complete -c drgnx -n __fish_use_subcommand -a open -d 'Open folders and files in drgnx'
    complete -c drgnx -n __fish_use_subcommand -a doctor -d 'Is this machine ready for drgnx?'
    complete -c drgnx -n __fish_use_subcommand -a build -d 'Byte-compile drgnx'
    complete -c drgnx -n __fish_use_subcommand -a test -d 'Run the tests'
    complete -c drgnx -n __fish_use_subcommand -a ui -d 'Headless GUI Emacs sessions'
    complete -c drgnx -n __fish_use_subcommand -a macos-app -d 'Install drgnx.app (macOS)'
    complete -c drgnx -n __fish_use_subcommand -a sync -d 'Install the packages drgnx needs'
    complete -c drgnx -n __fish_use_subcommand -a upgrade -d 'Newest packages'
    complete -c drgnx -n __fish_use_subcommand -a rollback -d 'The packages of an earlier generation'
    complete -c drgnx -n __fish_use_subcommand -a generations -d 'List the package generations'
    complete -c drgnx -n __fish_use_subcommand -a lock -d 'The package lock'
    complete -c drgnx -n __fish_use_subcommand -a bisect -d 'Find the module that breaks'
    complete -c drgnx -n __fish_use_subcommand -a service-unit -d 'Print the systemd user unit'
    complete -c drgnx -n __fish_use_subcommand -a onboard -d 'Set drgnx up'
    complete -c drgnx -n __fish_use_subcommand -a check -d 'Build, then every test tier'
    complete -c drgnx -n __fish_use_subcommand -a lease -d 'Run a command in a slot of the host lease'
    complete -c drgnx -n __fish_use_subcommand -a fmt -d "Format drgnx's Emacs Lisp"
    complete -c drgnx -n __fish_use_subcommand -a work -d 'The work tracker'
    complete -c drgnx -n __fish_use_subcommand -a hub -d 'The hub behind agents and jobs'
    complete -c drgnx -n __fish_use_subcommand -a job -d 'Jobs from plans'
    complete -c drgnx -n __fish_use_subcommand -a search -d 'Semantic search'
    complete -c drgnx -n __fish_use_subcommand -a keys -d 'Compare key profiles'
    complete -c drgnx -n __fish_use_subcommand -a safe -d "Emacs with drgnx's core only"
    complete -c drgnx -n __fish_use_subcommand -a help -d 'Show drgnx usage'
    complete -c drgnx -n __fish_use_subcommand -a shell -d 'Add the drgnx line to your shell rc file'
    complete -c drgnx -n __fish_use_subcommand -a secrets -d 'Provider keys to a second machine'
    complete -c drgnx -n __fish_use_subcommand -a bootstrap -d 'Set this machine up from your configuration'
    complete -c drgnx -n __fish_use_subcommand -a update -d 'Update this install to GitHub main'
    complete -c drgnx -n __fish_use_subcommand -a coord -d 'Serve the coordination tools to an agent outside drgnx'
    complete -c drgnx -n __fish_use_subcommand -s t -d 'Open in this terminal'
    complete -c drgnx -n __fish_use_subcommand -l gui -d 'Open in a window'

    # Commands that take no file: no file names after them.
    complete -c drgnx -n '__fish_seen_subcommand_from doctor build upgrade rollback generations lock macos-app check test hub' -f

    # open, doctor, test, sync, lock, onboard, check, fmt
    complete -c drgnx -n '__fish_seen_subcommand_from open' -l check -d 'Start the daemon if needed, print its Emacs version'
    complete -c drgnx -n '__fish_seen_subcommand_from open' -l wait -d 'Return when you are done with the files'
    complete -c drgnx -n '__fish_seen_subcommand_from open' -s t -d 'In this terminal'
    complete -c drgnx -n '__fish_seen_subcommand_from open' -l gui -d 'A window, even over SSH or without a display'
    complete -c drgnx -n '__fish_seen_subcommand_from doctor' -l json -d 'Machine-readable'
    complete -c drgnx -n '__fish_seen_subcommand_from doctor' -l dev -d 'Also the tools to develop drgnx'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l one-process -d 'Every test file in one Emacs'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l ui -d 'GUI tests in a headless session'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l scenario -d 'Behaviour scenarios'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l config -x -a 'drgnx gryphn' -d 'Configuration of the session'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l bench -d 'The workbench vs treemacs and ibuffer'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l perf -d 'Input latency, redisplay, frames, GC'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l audit -d 'What each hook function costs'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l soak -d 'The workloads in a loop'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l container -d 'Inside a container'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l install -d 'install.sh in fresh distribution containers'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l bootstrap -d 'drgnx bootstrap on a fresh Fedora container'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l fedora -x -a '44 45' -d 'Fedora release for --bootstrap'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l leaks -d 'Report what each test file leaves behind'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l shuffle -d "Each file's tests in a random order (=SEED fixes it)"
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l find-polluter -x -d 'Bisect to the test that breaks TEST'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l tty -d 'Terminal tests: Emacs in private tmux servers'
    complete -c drgnx -n '__fish_seen_subcommand_from test' -l compositor -x -a 'mutter sway x11 i3 kwin niri' -d 'Compositor of the GUI session'
    complete -c drgnx -n '__fish_seen_subcommand_from test; and __fish_seen_argument -l install' -a 'fedora-44 debian-trixie ubuntu-26.04 fedora-45 archlinux' -d 'Distribution image'
    complete -c drgnx -n '__fish_seen_subcommand_from sync' -l offline -d 'From the lock and the cache'
    complete -c drgnx -n '__fish_seen_subcommand_from sync' -l seed -r -d 'Copy another elpa first'
    complete -c drgnx -n '__fish_seen_subcommand_from sync' -l prune -d 'Remove packages the manifest no longer needs'
    complete -c drgnx -n '__fish_seen_subcommand_from sync' -l dry-run -d 'With --prune: only list them'
    complete -c drgnx -n '__fish_seen_subcommand_from lock' -l ship -d 'Write etc/drgnx.lock.eld'
    complete -c drgnx -n '__fish_seen_subcommand_from onboard' -l non-interactive -d 'No questions'
    complete -c drgnx -n '__fish_seen_subcommand_from onboard' -l again -d 'Run the steps again'
    complete -c drgnx -n '__fish_seen_subcommand_from onboard' -l preset -x -a 'minimal ide full-ai' -d 'Module preset'
    complete -c drgnx -n '__fish_seen_subcommand_from onboard' -l keys -x -a '(__drgnx_keys)' -d 'Key profile'
    complete -c drgnx -n '__fish_seen_subcommand_from onboard' -l theme -x -d 'Theme'
    complete -c drgnx -n '__fish_seen_subcommand_from onboard' -l roots -r -d 'Folders to look for projects in'
    complete -c drgnx -n '__fish_seen_subcommand_from onboard' -l todos -d 'Import TODOs'
    complete -c drgnx -n '__fish_seen_subcommand_from onboard' -l step -x -a 'environment look-and-keys projects ai search agents daemon portability finish' -d 'Run one step'
    complete -c drgnx -n '__fish_seen_subcommand_from check' -l no-perf -d 'Skip the performance tier'
    complete -c drgnx -n '__fish_seen_subcommand_from check' -l no-gui -d 'Skip the GUI tiers'
    complete -c drgnx -n '__fish_seen_subcommand_from check' -l jobs -x -d 'Parallel jobs'
    complete -c drgnx -n '__fish_seen_subcommand_from check' -l shards -x -d 'Shards'
    complete -c drgnx -n '__fish_seen_subcommand_from lease' -l wait -x -d 'Seconds to wait for a slot'
    complete -c drgnx -n '__fish_seen_subcommand_from fmt' -l check -d 'Only report'

    # work, hub, job, search, keys, ui
    complete -c drgnx -n '__fish_seen_subcommand_from work; and not __fish_seen_subcommand_from record scan status' -f -a record -d 'Link commits to a task'
    complete -c drgnx -n '__fish_seen_subcommand_from work; and not __fish_seen_subcommand_from record scan status' -f -a scan -d 'Read specs, plans and the board'
    complete -c drgnx -n '__fish_seen_subcommand_from work; and not __fish_seen_subcommand_from record scan status' -f -a status -d 'Every plan'
    complete -c drgnx -n '__fish_seen_subcommand_from work; and __fish_seen_subcommand_from record' -l task -x -d 'Task id'
    complete -c drgnx -n '__fish_seen_subcommand_from work; and __fish_seen_subcommand_from scan' -l board -r -d 'Board file'
    complete -c drgnx -n '__fish_seen_subcommand_from work; and __fish_seen_subcommand_from status' -l json -d 'Machine-readable'
    complete -c drgnx -n '__fish_seen_subcommand_from hub; and not __fish_seen_subcommand_from start stop status' -f -a start -d 'Start the hub'
    complete -c drgnx -n '__fish_seen_subcommand_from hub; and not __fish_seen_subcommand_from start stop status' -f -a stop -d 'Stop the hub'
    complete -c drgnx -n '__fish_seen_subcommand_from hub; and not __fish_seen_subcommand_from start stop status' -f -a status -d 'Is it running?'
    complete -c drgnx -n '__fish_seen_subcommand_from hub' -l json -d 'Machine-readable'
    complete -c drgnx -n '__fish_seen_subcommand_from job; and not __fish_seen_subcommand_from propose approve resume stop status' -f -a propose -d 'A job from a plan'
    complete -c drgnx -n '__fish_seen_subcommand_from job; and not __fish_seen_subcommand_from propose approve resume stop status' -f -a approve -d 'Run a proposed job'
    complete -c drgnx -n '__fish_seen_subcommand_from job; and not __fish_seen_subcommand_from propose approve resume stop status' -f -a resume -d 'Resume a paused job'
    complete -c drgnx -n '__fish_seen_subcommand_from job; and not __fish_seen_subcommand_from propose approve resume stop status' -f -a stop -d 'Stop a job'
    complete -c drgnx -n '__fish_seen_subcommand_from job; and not __fish_seen_subcommand_from propose approve resume stop status' -f -a status -d 'Jobs and their state'
    complete -c drgnx -n '__fish_seen_subcommand_from job; and __fish_seen_subcommand_from propose' -l repo -r -d 'Repository'
    complete -c drgnx -n '__fish_seen_subcommand_from job; and __fish_seen_subcommand_from propose approve resume' -l budget -x -d 'Budget in USD'
    complete -c drgnx -n '__fish_seen_subcommand_from job; and __fish_seen_subcommand_from propose' -l auto -d 'Approve at once'
    complete -c drgnx -n '__fish_seen_subcommand_from job; and __fish_seen_subcommand_from status' -l json -d 'Machine-readable'
    complete -c drgnx -n '__fish_seen_subcommand_from search; and not __fish_seen_subcommand_from index query mcp' -f -a index -d 'Build or refresh a project index'
    complete -c drgnx -n '__fish_seen_subcommand_from search; and not __fish_seen_subcommand_from index query mcp' -f -a query -d 'Ask a question'
    complete -c drgnx -n '__fish_seen_subcommand_from search; and not __fish_seen_subcommand_from index query mcp' -f -a mcp -d 'Serve the search tool to an agent'
    complete -c drgnx -n '__fish_seen_subcommand_from search; and __fish_seen_subcommand_from index' -l rebuild -d 'From scratch'
    complete -c drgnx -n '__fish_seen_subcommand_from search; and __fish_seen_subcommand_from query' -s k -x -d 'Number of chunks'
    complete -c drgnx -n '__fish_seen_subcommand_from keys; and not __fish_seen_subcommand_from ui diff' -f -a diff -d 'Compare against gryphn'
    complete -c drgnx -n '__fish_seen_subcommand_from keys; and __fish_seen_subcommand_from diff' -l against -x -d 'What to compare with'
    set -l __drgnx_ui_subs 'start frame stop ls reap state shot click keys type measure mcp test-ui test-ui-session'
    complete -c drgnx -n "__fish_seen_subcommand_from ui; and not __fish_seen_subcommand_from $__drgnx_ui_subs" -f -a "$__drgnx_ui_subs" -d 'Session command'
    complete -c drgnx -n '__fish_seen_subcommand_from ui; and __fish_seen_subcommand_from start' -l config -x -a 'minimal drgnx gryphn' -d 'Configuration of the session'
    complete -c drgnx -n '__fish_seen_subcommand_from ui; and __fish_seen_subcommand_from start' -l size -x -d 'WxH'
    complete -c drgnx -n '__fish_seen_subcommand_from ui; and __fish_seen_subcommand_from start' -l daemon -d 'No frame yet'
    complete -c drgnx -n '__fish_seen_subcommand_from ui; and __fish_seen_subcommand_from click' -l buffer -x -d 'Buffer'
    complete -c drgnx -n '__fish_seen_subcommand_from ui; and __fish_seen_subcommand_from click' -l text -x -d 'Text'
    complete -c drgnx -n '__fish_seen_subcommand_from ui; and __fish_seen_subcommand_from click' -l button -x -d 'Button'
    complete -c drgnx -n '__fish_seen_subcommand_from ui; and __fish_seen_subcommand_from click' -l count -x -d 'Count'
    complete -c drgnx -n '__fish_seen_subcommand_from ui; and __fish_seen_subcommand_from click' -l hold-ms -x -d 'Hold in ms'
    complete -c drgnx -n '__fish_seen_subcommand_from shell' -f
    complete -c drgnx -n '__fish_seen_subcommand_from shell; and not __fish_seen_subcommand_from install line' -a install -d 'Add the line to your rc file, after you say yes'
    complete -c drgnx -n '__fish_seen_subcommand_from shell; and not __fish_seen_subcommand_from install line' -a line -d 'Print the line'
    complete -c drgnx -n '__fish_seen_subcommand_from shell; and __fish_seen_subcommand_from install line' -l shell -x -a 'zsh bash fish' -d 'Which shell'
    complete -c drgnx -n '__fish_seen_subcommand_from shell; and __fish_seen_subcommand_from install' -l yes -d 'Print the line, write nothing'

    # secrets
    complete -c drgnx -n '__fish_seen_subcommand_from secrets; and not __fish_seen_subcommand_from export import ls' -f -a export -d 'Keys into secrets.age'
    complete -c drgnx -n '__fish_seen_subcommand_from secrets; and not __fish_seen_subcommand_from export import ls' -f -a import -d 'The keys of secrets.age into the keyring'
    complete -c drgnx -n '__fish_seen_subcommand_from secrets; and not __fish_seen_subcommand_from export import ls' -f -a ls -d 'The hosts in secrets.age'
    complete -c drgnx -n '__fish_seen_subcommand_from secrets; and __fish_seen_subcommand_from export' -l recipient -x -d 'age recipient'
    complete -c drgnx -n '__fish_seen_subcommand_from secrets; and __fish_seen_subcommand_from import ls' -l identity -r -d 'age identity file'
    complete -c drgnx -n '__fish_seen_subcommand_from secrets; and __fish_seen_subcommand_from import' -l replace -d 'Overwrite a different key in the keyring'

    complete -c drgnx -n '__fish_seen_subcommand_from service-unit' -l refresh -d 'Point the installed unit at the Emacs drgnx uses'
    # update, coord
    complete -c drgnx -n '__fish_seen_subcommand_from update' -f
    complete -c drgnx -n '__fish_seen_subcommand_from update' -l quiet -d 'One line, for the timer'
    complete -c drgnx -n '__fish_seen_subcommand_from update' -l back -d 'Return to the commit before the last update'
    complete -c drgnx -n '__fish_seen_subcommand_from update' -l restart -d 'Restart the drgnx service after a successful update'
    complete -c drgnx -n '__fish_seen_subcommand_from update' -l auto -x -a 'on off status' -d 'A daily timer'
    complete -c drgnx -n '__fish_seen_subcommand_from coord' -f
    complete -c drgnx -n '__fish_seen_subcommand_from coord; and not __fish_seen_subcommand_from mcp' -a mcp -d 'Serve the coordination tools over stdio'
    complete -c drgnx -n '__fish_seen_subcommand_from coord; and __fish_seen_subcommand_from mcp' -l kind -x -d 'The agent: claude, codex, zed…'

    # bootstrap
    complete -c drgnx -n '__fish_seen_subcommand_from bootstrap' -l config -r -d 'Your configuration repository (https or a path)'
    complete -c drgnx -n '__fish_seen_subcommand_from bootstrap' -l chezmoi -r -d 'A chezmoi source repository instead'
    complete -c drgnx -n '__fish_seen_subcommand_from bootstrap' -l identity -r -d 'age identity file for secrets.age'
    complete -c drgnx -n '__fish_seen_subcommand_from bootstrap' -l step -x -a 'preflight config keys sync onboard desktop shell doctor' -d 'Run only this step'
    complete -c drgnx -n '__fish_seen_subcommand_from bootstrap' -l dry-run -d 'Say what each step would do, change nothing'
    complete -c drgnx -n '__fish_seen_subcommand_from bootstrap' -l yes -d 'Confirm the age/chezmoi install and the key import'
    complete -c drgnx -n '__fish_seen_subcommand_from bootstrap' -l replace -d 'Overwrite a different key in the keyring'

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
            printf '\e]51;e;J\e\\\\'
            printf '\e]51;e;A;%s;%s\e\\\\' (printf %s $hostname | base64 | string join '') (printf %s $PWD | base64 | string join '')
            printf '\e]51;e;B\e\\\\'
        end
    end
end

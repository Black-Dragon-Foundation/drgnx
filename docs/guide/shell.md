# Your shell and drgnx

New Terminal (`C-S-\`` in the VS Code profile) runs your own shell in a real terminal ([eat](https://codeberg.org/akib/emacs-eat))
in the panel. Three small files in `etc/shell/` make that shell work better with drgnx. They are optional: without
them the terminal still works.

## The one line

Add one line to your shell's rc file, naming the file in your drgnx checkout:

| Shell | File | The line |
| --- | --- | --- |
| zsh | `~/.zshrc` | `source /path/to/drgnx/etc/shell/drgnx.zsh` |
| bash | `~/.bashrc` | `source /path/to/drgnx/etc/shell/drgnx.bash` |
| fish | `~/.config/fish/config.fish` | `source /path/to/drgnx/etc/shell/drgnx.fish` |

drgnx never edits your rc files on its own; you add the line.

What the line does:

- **Tab completion for `drgnx`** (see below). In zsh the directory with `_drgnx` goes on `fpath` (a `compinit` that
  runs later finds it; one that already ran gets `compdef _drgnx drgnx`). In bash it is `complete -F _drgnx drgnx`.
  In fish, `complete -c drgnx` lines.
- **Inside drgnx's terminal only**, eat's shell integration: eat learns the directory you are in (the terminal's
  `default-directory` follows `cd`), where each prompt starts, whether the last command failed (the margin mark), and
  whether a command is running. In zsh and bash the line sources the integration file that comes with eat. Eat
  ships none for fish, so `drgnx.fish` has its own few lines for it. Eat's file also hands Emacs your shell history
  with `tail` on `$HISTFILE`; when that is not a readable file (zsh sets no `HISTFILE` unless your rc does, and bash's
  is not written until your first shell exits) the file is sourced with `HISTFILE=/dev/null` for that moment only, so
  no `tail: cannot open` greets you, and your `HISTFILE` stays as it was.

What it never does:

- it prints nothing, and runs no program while your shell starts (no `uname`, no `hostname`, no fork: the files hold
  functions and builtin calls only);
- it never touches `PS1`, `PROMPT`, `PROMPT_COMMAND`, `fish_prompt`, or your plugin manager (oh-my-zsh, zinit,
  fisher, ...). Outside eat the only change is completion.

**Cost:** measured with `zsh -i -c exit` and `bash -i -c exit` (20 runs each, interleaved, median), the line adds
less than a millisecond (0.2 ms in zsh 5.9, under 0.15 ms in bash 5.3). The test `drgnx-shell-files/startup-cost`
holds it under 5 ms.

## What completes

`drgnx <TAB>` offers the commands (`open`, `onboard`, `doctor`, `test`, `sync`, `work`, `job`, `search`, ...) and the
files and folders of the current directory, since `drgnx PATH` opens them. `drgnx -<TAB>` offers `-h` and `--help`.
After a command, `-<TAB>` offers that command's options (`drgnx onboard --<TAB>`, `drgnx test --<TAB>`, `drgnx doctor
--<TAB>`), and the commands that have subcommands offer them (`drgnx work <TAB>`: `record`, `scan`, `status`;
likewise `hub`, `job`, `search`, `keys` and `ui`). Options that take a value complete it:

- `drgnx onboard --step` the step ids, `--preset` the presets (`minimal`, `ide`, `full-ai`), `--keys` the key profiles
  (the names of the files in the checkout's `keys/`, found when you press TAB);
- `drgnx test --config` and `drgnx ui start --config` the configurations, `drgnx test --install` the distribution
  images;
- paths (`--roots`, `--seed`, `--repo`, `--board`, ...) complete as files and folders.

The lists are written into the three files (`_drgnx` for zsh, `drgnx.bash`, `drgnx.fish`), so TAB starts no Emacs and
runs no program: the only thing read is the `keys/` folder for `--keys`. They cannot go stale unnoticed: a test reads
`bin/drgnx` and fails when a command or option of `drgnx help` is missing from any of the three files, and checks the
onboarding steps and presets against the ones the code defines. A new command or option in `bin/drgnx` is added to
those three files in the same change.

## The integration is on by default inside the terminal

With the line in your rc file there is nothing more to switch on: inside eat the shell reports its prompts and its
commands. That is what lets drgnx tell an idle shell from a running program:

- **An idle shell never makes drgnx ask** "programs still running" when you quit or close the terminal. With the
  integration the shell says so at every prompt; a command running (`make`, `sleep`, `vim`) makes drgnx ask once.
- **Without the integration** (you did not add the line, or your prompt theme dropped eat's marks, below) drgnx treats
  a terminal as running only when its shell has a child process. A `sleep 100` is asked about when you close that
  terminal; on quit it is asked about too once the session side of this lands (until then quit does not ask about a
  shell without the integration; closing the terminal does). An idle shell is not asked about. Two limits: a shell
  builtin that waits (`read`, a long `while` loop in the shell itself) has no child process and is not seen; and a
  shell that keeps a helper process running all the time (zsh with powerlevel10k's `gitstatusd`, a coprocess) always
  has a child, so without the integration it counts as running. That is one more reason to add the line.

## `EDITOR`: git and drgnx reach the Emacs hosting the terminal

The terminal starts with `EDITOR`, `VISUAL` and `GIT_EDITOR` pointing at this Emacs's server, so `git commit` opens
its message in drgnx. Your shell's rc file runs after that, so **an rc that exports `EDITOR` (or `VISUAL`,
`GIT_EDITOR`) overrides drgnx's**, and `git commit` then opens your own editor. To keep both, export yours only
outside drgnx's terminal:

```sh
# bash, zsh
case "$INSIDE_EMACS" in *eat*) ;; *) export EDITOR=vim ;; esac
```

```fish
# fish
string match -q '*eat*' -- "$INSIDE_EMACS"; or set -gx EDITOR vim
```

## If your prompt theme drops eat's prompt marks

Eat finds the prompt by marks it adds around `PS1` (zsh, bash) and by the functions `__eat_precmd` and
`__eat_preexec`. A prompt theme (powerlevel10k, starship, oh-my-posh, a plugin that rewrites `PS1`) can replace the
prompt after the marks went in, and the margin marks and the command-running state go with it. Source the drgnx line
**after** the theme is loaded (last in `.zshrc` / `.bashrc`), and do not remove eat's `precmd` / `preexec` hooks. With
starship, keep `eval "$(starship init ...)"` above the line; with powerlevel10k, put the line after
`source ~/.p10k.zsh`. If marks are still missing, drgnx falls back to the child-process rule above: nothing breaks,
it only knows less.

## fish

Eat ships no integration for fish, so `drgnx.fish` defines two event handlers, `__drgnx_eat_preexec` and
`__drgnx_eat_prompt`, that send what eat's zsh integration sends from `precmd` and `preexec`: the host and directory,
the start of each prompt (and the "a new prompt is coming" mark, `J`, as eat's zsh and bash scripts send it), the command
line, that a command started, and its exit status. The one thing missing is the prompt-end mark: fish cannot add it without redefining `fish_prompt`, which drgnx never does. So in fish:

- the directory, the failed-command mark, and "a command is running" all work;
- the prompt annotation and eat's line mode use bash and zsh's prompt-end mark and are unavailable in fish.

The handlers run `base64` once per prompt, inside eat only.

## "eat is not installed yet, so this is eshell"

New Terminal needs the `eat` package. Until it is synced, New Terminal opens eshell and says so once. Run
`drgnx sync` (see [Packages](packages.md)) and open a new terminal. For a remote folder (TRAMP) and on Windows, New
Terminal is always eshell.

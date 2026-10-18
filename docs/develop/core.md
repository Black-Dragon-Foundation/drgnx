# The drgnx core

The core is what every drgnx session loads before any module: paths, staged hooks, the no-prompt guard, the
command registry and every surface generated from it, the command palette, and a minimal module system. It uses
no third-party packages. Boot it with `emacs --init-directory <checkout>/init` — or in a harness session with
`bin/drgnx ui start --config drgnx`.

```
init/early-init.el   packages not activated by Emacs (drgnx-init activates drgnx's own — packages.md); no tool bar
init/init.el         core/ on the load path, (require 'drgnx), (drgnx-init); a plain GUI start (not a daemon,
                     not drgnx safe) serves `drgnx PATH' under the name drgnx unless another drgnx does
core/drgnx.el        drgnx-init: guard on, staged hooks armed, keep-running choice read, the first window's Welcome
                     (a first start only), packages activated, core commands, modules, surfaces (DRGNX_SAFE — drgnx
                     safe — skips packages and modules)
core/drgnx-session.el  drgnx PATH's Emacs side, Open Folder…, keep running or quit, Quit drgnx (../guide/opening.md)
core/drgnx-macos.el  the drgnx app on macOS (drgnx macos-app; ../guide/opening.md)
modules/<category>/drgnx-<name>.el   one drgnx-module-define per file
```

## Paths (`drgnx-paths.el`)

`drgnx-dir` is the checkout (code only, never written to). User configuration: `(drgnx-user-dir)` —
`$DRGNX_CONFIG_DIR` or `~/.config/drgnx/`. State and caches: `(drgnx-state-dir)` and `(drgnx-cache-dir)` under
the XDG directories. Packages: `(drgnx-data-dir)` — `$DRGNX_DATA_DIR` or `~/.local/share/drgnx/` — holds `elpa/`
(the packages every session uses) and `generations/`; `(drgnx-package-cache-dir)` keeps downloaded package files
([packages.md](../guide/packages.md)).
Started with `--init-directory <checkout>/init`, Emacs keeps its own state (`user-emacs-directory`: auto-save list,
histories) in `(drgnx-state-dir)emacs/` and native code in `(drgnx-cache-dir)eln-cache/` (`init/early-init.el`), so
nothing is written into the checkout; a harness session keeps both in its run directory.

## Staged hooks (`drgnx-hooks.el`)

Work that need not happen at startup hangs on a stage and runs once, when the stage is first reached:
`drgnx-first-input-hook` (before the first command), `drgnx-first-file-hook` (first visited file),
`drgnx-first-gui-frame-hook` (first graphical frame — for a daemon, the first `emacsclient -c`). Each function
runs under its own error guard; errors are collected in `drgnx-hooks-problems`, never shown as prompts.

## No prompts in automatic paths (`drgnx-guard.el`)

A prompt asked from a timer, a hook or while the daemon starts has nobody to answer it, and the daemon freezes.
`drgnx-guard-mode` (on in every drgnx session) makes `y-or-n-p`, `yes-or-no-p`, `read-string`,
`read-from-minibuffer`, `completing-read`, `read-passwd`, `read-number`, `read-file-name`,
`read-directory-name`, `read-buffer`, `read-multiple-choice`, `read-answer`, `read-key` and `read-char-choice`
signal `drgnx-prompt-in-automatic-path` instead — naming the prompt and where it was asked from — when called
(`read-event` is left alone: `sit-for` uses it):

- from a timer (detected by wrapping `timer-event-handler`; commands run by a nested command loop, such as a
  minibuffer opened by a command, are not timer code);
- inside `(drgnx-automatic …)` — use it for hook functions, process filters and sentinels (Emacs calls those
  from C, so they cannot be detected);
- while a daemon initialises — until the last `window-setup-hook` function, so `after-init-hook` and
  `emacs-startup-hook` count too.

## Command registry (`drgnx-registry.el`)

Every command is registered once, without keys:

```elisp
(drgnx-command-define 'palette
  :category "View" :title "Command Palette"
  :command #'drgnx-palette :menu '("View") :doc "Every command by name, with its key")
```

Keys: `:title`, `:category`, `:command` (required), `:scope` (`app` default, `editing` or `window` — which key-profile
layers key it), `:map` (the keymap its keys go into by default: nil for global, a keymap symbol, or
`(FEATURE . KEYMAP)` for a keymap that exists once FEATURE loads), `:menu` (menu-bar path), `:context` (right-click
contexts), `:context-first`, `:doc` and `:when` (a predicate: the command is offered only while it holds).
Redefining an id replaces it. **Keys come from key profiles** ([keys.md](../guide/keys.md)); the active keys of a command
are in its `bound` slot, which every surface reads. The entries keep the ids of the gryphn layer's registry, which
this is ported from.

## Surfaces (`drgnx-surfaces.el`, `drgnx-palette.el`)

Generated from the registry, never written by hand, showing the keys of the active key profiles: the menu bar,
right-click menus (contexts via `drgnx-surfaces-define-context`), which-key labels (when which-key is present),
the **key sheet** ("Keyboard Shortcuts", `*drgnx keys*`), a markdown cheat sheet (`drgnx-surfaces-export-markdown`), "next time:
KEY" tips after a command run from a menu or the palette, and the **command palette** (`C-S-p` in every profile): every available
command as "Category: Title" with its key and description beside it, through the normal completion UI.

**Run hook and usage counter.** `drgnx-surfaces-run` (what the palette and the menus call) runs
`drgnx-surfaces-run-functions` with the command id after the command ran; an error in a member is swallowed. The
first member counts the run: in memory only, so a run costs nothing noticeable. The counts are written at idle, at
most once a minute and at exit, never prompting, to `command-usage.eld` in the state dir
(`drgnx-shortcuts-usage-file`): `((ID COUNT (DAY . N)…)…)`, with the per-day counts (`time-to-days`) of the last 7
days. The file stays on your machine; it feeds the suggestions of the Keyboard Shortcuts editor ("you ran X 12
times this week; give it a key?"). Read it with `drgnx-surfaces-usage-count` and `drgnx-surfaces-usage-week`.

## Modules (`drgnx-modules.el`)

```elisp
(drgnx-module-define 'core/basics
  :doc "Quiet, predictable defaults and the basic file and view commands."
  :stage 'startup
  :setup (lambda () …))
```

Module files are `modules/<category>/drgnx-<name>.el`. Stages: `startup` (during `drgnx-init`) and `idle` (once
Emacs is idle). Each setup runs under its own error guard and is timed; a file that fails to load is reported as
a module too. "Help: Module Report" (`drgnx-modules-show-report`) lists stage, milliseconds and errors. Flags,
settings, doctor checks, more stages and the modules index come with M4.

## Build (`drgnx-build.el`)

`bin/drgnx build` byte-compiles `core/`, `wb/` and `modules/` in place (`.elc` files are not tracked); with native
compilation available, Emacs then compiles them natively in the background as they load. Compiled drgnx is several
times faster and makes far less garbage. `install.sh` runs it; drgnx sets `load-prefer-newer`, so a stale `.elc`
never shadows newer source. The build must stay warning-free (`test/unit/build-test.el`).

## The Emacs `bin/drgnx` runs in

The shell function `emacs_bin` picks the one Emacs every subcommand uses: `$DRGNX_EMACS`, else the first line of
`$DRGNX_CONFIG_DIR/emacs` (default `~/.config/drgnx/emacs`, written by `install.sh`'s `remember_emacs`) when it
names an executable file, else `emacs`. The file is read as a path, never evaluated. A new subcommand calls
`"$(emacs_bin)"`, never a bare `emacs`. All of them run with `load-prefer-newer`, so a stale `.elc` after a pull
never prints before the output. `emacsclient_bin` is that Emacs's `emacsclient` (beside it, or in an Emacs.app's
`Contents/MacOS/bin/`; else PATH's) — what `drgnx open` and `drgnx PATH` talk to the daemon with
([opening.md](../guide/opening.md)). `test --install` limits each image to an hour with `timeout`, else `gtimeout`.
`test/unit/bin-test.el` covers it with fake Emacs scripts.

## TOML (`drgnx-toml.el`)

A minimal reader and a writer that changes one table only, for config files drgnx edits but does not own (the
agent settings pages use it on Codex's `config.toml`).

| Function | Does |
| --- | --- |
| `drgnx-toml-parse STRING` | The whole file as an alist in file order: tables are alists, arrays vectors (arrays of tables are vectors of alists), `t` / `:false`, numbers, strings; a date or time is `(:date . "TEXT")` and is written back bare. Comments, bare/quoted/dotted keys, `[a.b]`, `[[a.b]]`, basic/literal/multi-line strings, inline tables and multi-line arrays are read. A syntax error signals `drgnx-toml-error` with data `(LINE MESSAGE)`. |
| `drgnx-toml-table-region STRING PATH` | `(BEG . END)` (0-based) of `[PATH]` and its sub-tables (`[PATH.x]`), up to the last key line; blank lines and comments after it belong to what follows. nil when absent. |
| `drgnx-toml-set-table STRING PATH ALIST` | STRING with that region replaced by fresh text (nested alists as inline tables), added at the end when absent (after a blank line), removed when ALIST is nil. |
| `drgnx-toml-set-array-entry STRING PATH PRED ALIST` | The same for the first `[[PATH]]` entry PRED (called with the entry as an alist) accepts; appended when none is. |
| `drgnx-toml-encode-value VALUE` | One value as TOML text. |

Every byte outside the changed region stays as it was: comments, order, unknown keys, spacing, line ends, a leading
byte order mark. New text uses the file's own line end (CRLF when its first line ends that way). PATH is a
list of keys, so dotted and quoted names (`("projects" "/p")`) work. A table that is defined some other way than by
its own header (dotted keys in a parent table, an inline table, an array of tables, a header split into
pieces, or a parent of an array of tables, which would become an inline array) is read but never written: the writer signals `drgnx-toml-error` with the line, so a caller reports it
and writes nothing. Text drgnx writes is re-encoded (comments inside the replaced table go), which is why callers keep one backup per write.

## Agent settings model (`drgnx-agent-config.el`)

What the settings pages of Claude Code, Codex, Gemini and Kimi Code share; each agent's own file (later tasks)
implements the three generic functions. Tests use `test/fixtures/agent-config-fixture.el` (`drgnx-agent-config-test-env`:
temp agent homes and HOME, a temp project, fake `claude`/`codex`/`kimi` scripts that log their argv); a test never
reads the user's real agent homes.

An item is a plist `(:kind :section mcp|hook|skill :name :from user|project|local|plugin|extension|system|legacy :file
:line :spec :enabled :readonly :problem)`; `:spec` is `(:type :command :args :env :url :headers)` for an MCP server
(`:env`, `:headers` alists), `(:event :matcher :command :timeout)` for a hook, `(:dir :description)` for a skill.

| Function | Does |
| --- | --- |
| `drgnx-agent-config-kinds`, `-title KIND` | `(claude codex gemini kimi)`; "Claude Code", "Codex", "Gemini", "Kimi Code". |
| `-home KIND` | The agent's user directory (trailing slash): `$CLAUDE_CONFIG_DIR` / `~/.claude`, `$CODEX_HOME` / `~/.codex`, `$GEMINI_CLI_HOME/.gemini` (gemini 0.64 replaces its home directory with that variable) / `~/.gemini`, `$KIMI_CODE_HOME` / `~/.kimi-code`. An empty variable counts as unset. |
| `-read KIND ROOT`, `-scopes KIND SECTION ROOT`, `-write KIND OP ITEM SCOPE ROOT CALLBACK` | Generic functions (`cl-defgeneric`, `eql` specializers on KIND) each agent file implements: everything configured as `(:rules :items :problems :routes :notes)`; where an add may go, `((SCOPE LABEL FILE)…)`; add/edit/remove/toggle with a callback getting `(:ok t :note S)` or `(:error S)`. |
| `-json-read FILE` | `(:value V :indent N)`: objects are alists with symbol keys in file order, arrays vectors, `:null`, `:false`. A missing or blank file is `(:value nil :indent 2)`; one that does not parse signals `drgnx-agent-config-unreadable` with `(FILE LINE MESSAGE)` (a trailing comma names the comma's line). |
| `-json-write FILE VALUE INDENT [EXPECT]` | Key order as in VALUE, INDENT spaces, a final newline; through `-write-text`, with the file's and the new text's JSON parse as checks. Unreadable files are never written. A VALUE that is not JSON is an error naming its place and type (`Not a JSON value at mcpServers.x.args (a list, expected a vector)`), never its content. |
| `-write-text FILE TEXT CHECK [VERIFY [EXPECT]]` | EXPECT (the text, or the modification time, seen when the caller read FILE): a FILE that differs now signals `drgnx-agent-config-changed` and nothing is touched (Claude Code rewrites `~/.claude.json` often). CHECK (called with FILE's current text) must not signal, else nothing is touched; VERIFY the same with TEXT. TEXT equal to what FILE holds is not written and the backup stays. Then FILE is copied to `FILE.drgnx-bak` (exactly one backup, with FILE's modes), TEXT goes to a temp file next to FILE with FILE's modes (0600 for a new file) and is renamed over it. A symlink is written through; directories it has to make get 0700. The TOML writes use it too. |
| `-secrets SPEC`, `-mask-text TEXT SECRETS` | Every env and header value, and the value of any key matching token, secret, key, password or authorization (case-insensitive; every string inside a list or object under such a key), longer than 3 characters. Also, in `:args`, `:url`, a hook's `:command` and every other string, only the secret part of: `NAME=VALUE` / `--flag=VALUE` with a secret-ish name, `Bearer`/`Basic`/`Token` values, `Authorization:` values, URL userinfo and secret-ish query parameters, well-known token shapes (`sk-`, `ghp_`, `github_pat_`, `xox?-`, `AKIA`, `AIza`, JWTs), the argument after a secret-ish flag, `-p`, `-H`/`--header` and `-e`/`--env`, and 24+ character `:url` path segments. `-mask-text` replaces each by `••••` and keeps the context. |
| `-cheap-status ITEM` | `(ok . DETAIL)`, `missing-command`, `no-url` or `unreadable`, from files and `exec-path` only: nothing is run. The detail is masked like any text shown (a URL keeps its host and path, not its secrets). |
| `-skills-in DIR FROM KIND`, `-new-skill DIR NAME DESCRIPTION` | Items for `DIR/*/SKILL.md` (name and description from the front matter); creates a skill, refusing an existing name. |

JSON that is tab-indented is re-written with 2 spaces; arrays are always written one entry per line.

## Claude Code's settings (`drgnx-agent-config-claude.el`)

The `claude` methods of the three generic functions, and `drgnx-agent-config-claude-routes`. Read: the files below;
write: only the entry that changed, with one backup next to the file. Credential files are never opened; no key is
looked up.

| What | Where |
| --- | --- |
| User MCP servers | `mcpServers` in `(drgnx-agent-config-claude-json-file)`: `$CLAUDE_CONFIG_DIR/.claude.json` when the variable is set, else `~/.claude.json` (not inside `~/.claude`). |
| Local MCP servers | `projects[ROOT].mcpServers` in the same file (ROOT without the trailing slash). |
| Project MCP servers | `ROOT/.mcp.json`. |
| Read only | The enabled plugins' servers (`plugin:PLUGIN:SERVER`), skills and `managed-mcp.json`; hooks of the managed settings (`managed-settings.json`, `managed-settings.d/*.json` in `/etc/claude-code`, `/Library/Application Support/ClaudeCode` on macOS). Plugins come from `plugins/installed_plugins.json` and `enabledPlugins`. |
| Hooks | `hooks` of `HOME/settings.json` (user), `ROOT/.claude/settings.json` (project), `ROOT/.claude/settings.local.json` (local). |
| Skills | `HOME/skills`, `ROOT/.claude/skills`; on or off by `skillOverrides` (`"off"`; absent is on; `name-only` and `user-invocable-only` still count as on). |
| Rules | `HOME/CLAUDE.md`, `ROOT/CLAUDE.md`, `ROOT/.claude/CLAUDE.md` when present. |

How a write goes (`-write 'claude OP ITEM SCOPE ROOT CALLBACK`; for an edit ITEM carries `:replaces`, the item it replaces):

- **User and local MCP servers** run `claude mcp add-json NAME JSON --scope S` / `claude mcp remove NAME --scope S` in ROOT
  (asynchronous, 20 s each; an edit is a remove, then an add; a backup of `.claude.json` is taken first). A server whose
  `drgnx-agent-config-secrets` is not empty never goes on a command line: `-merge-entry` re-reads the file, merges the one
  entry and writes it directly, and the note says to restart running Claude sessions. Claude Code rewrites the file every
  few seconds: each direct write passes what it read as EXPECT, so a file that changed is read again and the entry merged
  again, once; a second change is reported ("changed by another program") and nothing is written.
- **`.mcp.json`, hooks and `skillOverrides`** are edited directly (key order and indent kept). Switching a skill off
  writes `"off"` into the user's settings (a project skill: the project-local settings, private); switching it on removes
  an `"off"` from every settings file that has one.
- A server name is letters, digits, `.`, `-` and `_` and cannot start with `-` (it is a command-line argument).
- Errors name the file and line, never the entry's data (values are masked with `-secrets` besides).

`(drgnx-agent-config-claude-routes ROOT)` lists one route per Claude Code profile (command `claude-agent-acp`) with its
billing, derived from the provider and not from the profile's name: no `:ai` is the subscription; the OpenRouter
provider `openrouter`; a loopback URL `local`; any other provider (a `:key-env`) `per-token`, the vendor being the
provider's name. `:key-where` names the variable and the keyring host. An `env` entry of a settings file that sets
`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `ANTHROPIC_SMALL_FAST_MODEL` or
`ANTHROPIC_DEFAULT_*_MODEL` is a note ("overrides every profile's route"), by file and name, never the value.

## Doctor (`drgnx-doctor.el`)

`bin/drgnx doctor [--json] [--dev]` asks the Emacs drgnx will use (see above) whether this
machine is ready, and gives a fix for anything that is not:

```
OK    emacs-version        Emacs 31.1                 (30.2: WARN — works, 31.1 recommended; older: FAIL)
OK    native-compilation   native compilation works   (built without it, or libgccjit broken: FAIL)
OK    tree-sitter          tree-sitter available
OK    gui                  graphical build (pgtk)     (terminal-only: WARN)
WARN  security             known issues up to 31.1, fixed in 31.2 (TRAMP, Flymake, read-symbol-shorthands)
OK    git                  git found
```

Native compilation is checked by actually compiling a function, not only by asking whether it is built in. Any
FAIL makes the exit status 1. `--dev` adds the tools for developing drgnx (mutter, dbus-run-session, ImageMagick, a
pgtk Emacs) and the environment, container runtime and session launcher. Without any Emacs, the doctor prints the
installer command. Checks are defined with `drgnx-doctor-define`; modules will add their own (M4).

A check may be for one platform (`:platform 'linux` or `'macos`, as `drgnx-platform` says); on the other it is absent
from the results. The dev checks for mutter, dbus-run-session and a pgtk Emacs are Linux-only. macOS adds three
warnings with their facts: `macos-app` (`~/Applications/drgnx.app` exists; fix `drgnx macos-app`), `brew` (`brew` on
PATH, `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`; the doctor may run without Homebrew on PATH) and
`drgnx-on-path` (fix: `~/.local/bin` in the shell's profile: `~/.zprofile` for zsh (or, with `SHELL` unset, when it exists), else `~/.profile`, as
`drgnx-doctor--shell-profile` says; the same rule as `install.sh`).

## Tests

Batch: `test/unit/core-*-test.el`. The batch runner (`harness/run-ert.el`) gives the suite a temp HOME and drgnx
dirs, and unsets the provider keys (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`OPENAI_API_KEY`): no test reaches a paid model. In a session: `test/live/drgnx-boot-test.el` boots `config=drgnx` and checks
the registry, the guard (a `y-or-n-p` from a timer signals), the palette (`C-S-p`), the key sheet (F1) and the
module report. Scenarios run against drgnx with `bin/drgnx test --scenario`; the workbench ones skip until M3.

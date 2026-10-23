# Settings

Your settings in one place: `settings.el` in your config dir, the Settings page, and how they meet your own Lisp,
Customize and the packages you use. The contributor side is [docs/develop/settings.md](../develop/settings.md).

This page is being written; each section below comes with the part of drgnx it describes.

## The files

Your settings live in `settings.el` in your config dir ([files.md](files.md)). It is one Lisp form that drgnx reads
as data and never loads:

```elisp
;;; settings.el --- your settings  -*- lexical-binding: t; mode: lisp-data -*-
;; Written by drgnx Settings and by you. Kept sorted; a comment above an entry stays with it.
;; Values are data: write 80 or (a b), not '(a b). Code goes in config.el. drgnx reads this file; never load it.
(drgnx-settings
 :version 1
 (drgnx-agents-default "claude")
 ;; the review profile reads every project
 (drgnx-agents-profiles
  (("review" :command ("claude-agent-acp") :mode queue :model "opus" :doc "Reviews")))
 (eglot-autoshutdown t)
 (fill-column 100)
 (:mode python-ts-mode
  (fill-column 88)))
```

- **Entries** are `(VARIABLE VALUE)`. The value is written as it is and never evaluated: `80`, `"claude"`, `(a b)`.
  A leading `'` or `#'` is accepted and means the same value without it; drgnx itself never writes one.
- **Sections** hold entries for one place: `(:mode MODE ENTRY…)` applies in buffers of that major mode.
- **The head** `drgnx-settings` only marks the file. Loading the file by mistake stops at it, before any entry runs.
- **Workspace files** have the same shape under the head `drgnx-workspace-settings`: a repository's
  `.drgnx/settings.el`, shared with everyone who clones it, and your private workspace files. They may also hold
  `(:dir "SUBDIR/" ENTRY…)` for one folder and `(:eval FORM…)`, code that runs in the workspace's buffers.
- **Limits:** 1 MiB for a settings file, 64 KiB for a repository's `.drgnx/settings.el`. A bigger file is refused,
  never cut short.
- **A mistake.** A file that does not read (a missing paren, the wrong head, no `:version`, or one written by a newer
  drgnx) fails as a whole: drgnx names the file, the line and the column, keeps a last good copy of `settings.el` to
  fall back on, and writes nothing to it until you fix it. One malformed entry fails alone: the rest of the file
  stands. Two entries for the same variable in the same place: the first wins, and the second is named as a problem.

## Editing by hand

`settings.el` is yours as much as drgnx's: edit it in any editor, any time. When drgnx writes it (the Settings page,
an agent with a grant), it changes as little as it can:

- **One entry, one span.** Changing a setting replaces that entry's text and nothing else; every other byte of the
  file stays as you left it.
- **Sorted places, your order kept.** A new entry goes before the first entry whose name sorts after it, and
  sections go after the plain entries. A file you ordered by hand keeps your order: drgnx never re-sorts it behind
  your back. **Settings: Sort File** sorts the file (or the workspace settings file you are in) when you ask: entries
  by name, then sections by kind and name, each with its comments.
- **Comments.** The `;` lines directly above an entry (no blank line between) and a comment at the end of its last
  line belong to the entry: they stay when its value changes and go when it is removed. A comment inside a value is
  lost when drgnx replaces that value; put it above the entry instead.
- **The same text every time.** A value fits on one line up to column 100; a longer list breaks before each keyword,
  or one element per line, each line one column in. Your own print settings change nothing, so diffs stay small.
- **A second entry** for a variable goes when drgnx next writes that variable.
- **An open buffer.** If `settings.el` is open with unsaved edits, drgnx does not write it and says "settings.el has
  unsaved edits in a buffer; save or revert it first". An open buffer with no edits is reverted after drgnx writes.
- **Checked before it lands.** The new text is read back before it replaces the file; when anything but the change
  would differ, nothing is written. Two drgnx sessions never write the file at once.

## The Settings page (Task 26)

## Editing a value (Task 27)

## Who wins

Your Lisp wins. At start drgnx applies `settings.el` right after your packages are activated and before `custom.el`,
so `custom.el` (what Customize saved), `use-package :custom` and the `setq`s in `config.el` and your Lisp files all
come later and win, as they would in Emacs without drgnx.

- **A value in `settings.el` for a package that is not loaded yet** waits and applies when the package loads (at its
  `defcustom`, with the package's own setter). drgnx never loads a package for an ordinary setting.
- **A minor mode's variable** (`savehist-mode`, `display-time-mode`) loads its package when it is applied, exactly
  as the same entry in `custom.el` does: turning the mode on needs its code.
- **A change you make in Settings while Emacs runs** applies at once only when nothing else set that variable since:
  no `setq`, `setopt`, Customize, `use-package :custom` or colour theme. Otherwise it is saved in `settings.el` and
  kept for when it can apply (the row says who sets the variable instead), and the value in effect stays.
- **Customize** sees drgnx's values: `M-x customize-variable` shows them as set by a theme ("THEMED"), and
  `describe-variable` shows the original value.
- **A value that is wrong for its variable** (text where a number belongs) is skipped alone: the variable keeps its
  last good value from `settings.el` (or its default, for the agent and sandbox settings), and the problem names the
  line. When `settings.el` does not read at all (a missing parenthesis), every setting falls back the same way; the
  file's problem names the line and column.
- **A variable nobody defines** (a package you have not installed) keeps its entry; it applies when the package
  arrives.

## Where a value comes from

drgnx tells you where each value comes from, down to the file and line, and it says when it is not sure. It
explains the value Emacs has; it never works out a value of its own.

- **The layers, lowest first:** the package's default, a drgnx module, Settings (`settings.el:14`), Customize
  (`custom.el:9`, or "this session only"), your Lisp (`config.el:31`). In a buffer, per-language settings, your
  mode hooks, the workspace files, `.dir-locals.el` and file-local variables come on top.
- **Your Lisp, at its line.** While `custom.el`, `config.el` and your Lisp files load, drgnx notes the line each
  form starts at, file by file, so a `load` inside a form never hides the outer file. `setq`, `setopt`,
  `customize-set-variable`, `use-package :custom` and macros are all seen, because drgnx watches the variable itself.
- **Deferred.** A `with-eval-after-load` body, or a `use-package :config` that waits for its package, runs when the
  package loads. drgnx shows it as "your Lisp (config.el:4), deferred, first seen during config.el:8": the body's own
  line, and the form that loaded the package. That `require` is never blamed for the value.
- **A package's own default.** When a package defines a variable whose value Settings already holds, the value is
  Settings', not the line that loaded the package, also for a package loaded long after start.
- **A theme.** A theme you enable in `config.el` (`(load-theme 'newcomers-presets t)`) is shown as "theme
  newcomers-presets", not as that line of `config.el`.
- **Line unknown.** When the line cannot be confirmed (a compiled file, a `set` through a function, several setters
  in one form), drgnx says "your Lisp (config.el, line unknown)" and lists the lines that could have set it.
  Settings offers no Move or Undo on such a line.
- **Changed this session.** After start, a change by anything but Settings itself (`M-x set-variable`, a `setq` you
  evaluate) is shown as "changed this session".
- **Only one buffer.** A `setq` of a variable that is always per buffer (`fill-column`, `indent-tabs-mode`) in
  `config.el` sets only the buffer that was current, and the default stays. drgnx points this out: you probably
  meant `setq-default`.

## Changes apply at once (Task 13)

Edit `settings.el` by hand, let another program write it, or pull a new copy: drgnx notices and applies the changes
without a restart. It watches the folder, and also checks the file when you come back to the Emacs window and before the
Settings page draws, so a change is never missed. A value you took out of the file goes back to what it would be
without it. Nothing asks you anything; a file that does not read keeps the last good values and says so once.

Settings that drgnx owns (keys, agents, look, modules...) take effect right away: when one changes, from the file,
the Settings page or a `setq` in `config.el`, drgnx runs the setting's `:apply` the next time Emacs is idle. At start the
same happens once for every such setting whose value you changed in `config.el`.

## Modules and your settings

drgnx's modules choose some values for you (the tree-sitter modes, Evil's undo system, the frame's scroll bars).
Those choices sit just above the package's default, below everything you set:

- **Settings, Customize and your Lisp win over a module.** A module never overrides a value you saved with
  Customize, put in `settings.el` or set in your Lisp. The module's choice is kept and shows as "module lang/eglot"
  in the row's layers, and it applies again if you remove yours.
- **A list or alist that modules add to** (`major-mode-remap-alist`, `auto-mode-alist`): the modules add their own
  keys or elements. When you give the whole variable a value in Settings, your value replaces theirs, and the row
  says which entries it replaced. **Keep Module Entries** (*Settings: Keep Module Entries…* in the palette) changes
  that entry to merge per key instead: your keys win, and the modules' other keys stay. It writes `:merge alist` on
  the entry in `settings.el` and applies at once:

  ```elisp
  (major-mode-remap-alist ((c-mode . c-ts-mode)) :merge alist)
  ```

  `:merge append` keeps the modules' elements of a list and adds yours after them; `:merge lower-only` takes the
  lower of a module's number and yours.
- **Turning a module off** takes only its own choices away: a key it added goes only while it still holds the
  module's value, and a value you set since stays.

## Per language

A `(:mode MODE ENTRY…)` section of `settings.el` sets variables only in buffers of that mode (and the modes derived
from it):

```elisp
(:mode python-ts-mode
 (fill-column 88))
```

The value is set when the buffer's mode starts, before your mode hooks. So a `setq-local` in a mode hook beats it, and a
`.dir-locals.el`, a workspace file or a file-local variable beats that, as in stock Emacs. If one entry fails, the
buffer still opens; drgnx says so once per variable per session. Nothing is loaded for it: a variable of a package that
is not loaded yet gets a plain buffer-local value.

## Agents and AI settings (Task 15)

`agents.eld` and `ai.eld` are settings now. In `settings.el`:

| Setting | What |
|---|---|
| `drgnx-agents-profiles` | your agent profiles ([agents.md](agents.md)) |
| `drgnx-agents-default` | the profile New Agent Session offers on Return |
| `drgnx-agents-mcp` | the MCP servers agents get: `coordination`, `search` |
| `drgnx-agents-routes` | which profile does each job role ([jobs.md](jobs.md#routes-and-the-estimate)) |
| `drgnx-agents-openrouter` | which providers OpenRouter may use for agents ([ai.md](ai.md#openrouter-restrictions)) |
| `drgnx-agents-allow-unsandboxed` | whether agents may run without the sandbox (off) |
| `drgnx-ai-providers` | AI providers of your own, or presets moved ([ai.md](ai.md)) |
| `drgnx-ai-roles` | each role's chain of providers and models |

- **Strict.** The agents settings are `:on-error strict`: an entry with a mistake, or a `settings.el` that does not read,
  gives the shipped default for them, never a half-read value. The AI settings keep their last good value instead.
- **Never for agents or workspaces.** An agent cannot change them (`:agents never`), a workspace file or a
  `.dir-locals.el` cannot set the agents settings or the providers, and drgnx only ever reads their global value, so a
  buffer-local `setq-local` never reaches a profile or a provider. The same holds for the sandbox's
  `drgnx-sandbox-memory-max`, `drgnx-sandbox-secret-files` and `drgnx-sandbox-proxy-pinned-addresses`.
- **The shipped data.** The presets, the default roles and the built-in profiles are data in `settings/runtime-defaults.el`
  in the checkout, with the strict defaults. You do not edit that file; to change a preset, put a provider of the same id
  in `drgnx-ai-providers`, and to change a built-in profile, copy it into `drgnx-agents-profiles`.
- **The runtime.** The settings are marked as the ones the hub reads. Until the hub reads `settings.el` itself, the
  hub's Lisp half applies your entries when it starts.
- **An old file that stayed.** An `agents.eld` or `ai.eld` the migration left because it had a mistake is no longer
  read; a notice and the doctor say so (see [Moving from the old files](#moving-from-the-old-files)).

## Workspace settings

A workspace is a project folder. Your private settings for one live in `workspaces/<name>.el` in your config dir,
named after the project's folder (a second project with the same folder name gets `<name>-2.el`). The file says which
folder it belongs to; it never goes into the repository:

```elisp
(drgnx-workspace-settings
 :version 1
 :roots ("~/workspace/drgnx/")
 (fill-column 100)
 (drgnx-search-exclude ("vendor/**"))
 (:mode python-ts-mode (python-indent-offset 4))
 (:dir "docs/" (fill-column 72))
 (:eval (add-hook 'before-save-hook #'my-format-buffer nil t)))
```

- **It applies like `.dir-locals.el`,** through Emacs's own directory-local machinery: packages see the values as
  directory-local, and `describe-variable` says so. Inside the folder your private file wins over the project's
  `.dir-locals.el`; a `.dir-locals.el` in a subfolder (`src/.dir-locals.el`) wins inside that subfolder, as it does in
  Emacs, unless your file has its own `(:dir "src/" …)` section. File-local variables (`-*-` and `Local Variables:`)
  win over every workspace layer.
- **No question asked.** It is your file, so every value applies without the "unsafe local variables" prompt, and
  its `(:eval …)` code runs after its values. Nothing is ever added to `safe-local-variable-values`.
- **Refused, with the line:** a setting that has one value for all of Emacs (a global minor mode, `drgnx-agents-default`
  …: "set it in Settings → User"), and drgnx's security settings, which no workspace may set. The rest of the file
  applies; the problem names the file and the line.
- **`enable-local-variables`** is respected: when it is nil no workspace layer applies; when it is `:safe` only safe
  values apply.
- **Project settings** such as search's include and exclude globs are read with the project's folder rather than set
  in a buffer: your private file, then the shared file, then `settings.el`. A list like `drgnx-search-exclude` adds
  the workspace's globs to yours; a limit marked `:merge lower-only` can only be lowered by a workspace.
- **Changes apply at once** to the project's open buffers, as for `settings.el`, without restarting their modes.

## Shared settings

A repository can carry settings for everyone who works on it in `.drgnx/settings.el` (at most 64 KiB), with the same
shape as your private file. They apply below the repository's `.dir-locals.el` at the same folder, and below your
private file.

- **Safe values only, for now.** A cloned repository is someone else's file: of its entries only those whose value
  Emacs marks safe for the variable apply (`fill-column 100` does; a program to run does not), and its `(:eval …)`
  code does not run. Nothing prompts. Trusting a folder to apply more is described in "Trusted locations" below.
- **The same refusals** as your private file: global-only settings and drgnx's security settings never apply from it.
- **The old project files** `.drgnx/search.eld`, `.drgnx/ai.eld` and `.drgnx/large-files.eld` still work: drgnx reads
  them as entries of the shared file (`drgnx-search-include`, `drgnx-search-exclude`, `drgnx-search-off`,
  `drgnx-ai-roles`, `drgnx-large-files-ask-above`, `drgnx-large-files-chunks-above`). A large-file size there can only
  lower yours, as before.

## Trusted locations (Task 18)

## Reviewing a workspace's code (Task 19)

## Settings the runtime reads (Task 22)

## History and undo (Task 25)

## Your Lisp files

**Settings: Lisp Files** (the palette, the Options menu) lists every file of your Lisp in the order Emacs loads it,
then the files drgnx only reads:

1. the early files of `drgnx-user-lisp-files` (loaded at the end of `early-init.el`);
2. `custom.el`, what Customize saved;
3. `config.el`;
4. the other files of `drgnx-user-lisp-files`;
5. the files in your config dir that those loaded;
6. `settings.el` and the workspace settings files read this session, as data: read, never loaded.

Each file says whether it is on (turning a file off takes effect at the next start: code that ran cannot be
unloaded), whether it loaded, how long that took, and an error with its line. Under it come the settings it sets,
each with its line and whether it **won** (its value is the one in effect), **lost to** what won, or **?** when drgnx
cannot be sure (the line is unknown: [Where a value comes from](#where-a-value-comes-from)). A setting inside `when`, `unless`,
`with-eval-after-load` or a deferred `use-package` says "(conditional)".

**Findings** are things worth knowing, shown and never undone behind your back: the file moves `custom-file` or
changes `user-emacs-directory`, uses `user-emacs-directory`, or `setq`s a variable that is local to each buffer
(`fill-column`, `indent-tabs-mode`): that sets only the buffer it ran in, so the default stays; you probably meant
`setq-default`.

**RET** on any line opens the file at that line; `g` draws the page again. The page is a page of Settings; until the
Settings page exists it opens on its own.

## Moving a setting

**Settings: Move into Settings…** turns one setting of your Lisp into an entry of `settings.el`. On the Lisp files
page it takes the setting of the line you are on; elsewhere it asks which. It moves:

- a top-level `(setq VAR VALUE)`, `(setq-default …)`, `(setopt …)` or `(customize-set-variable 'VAR VALUE)`;
- one pair of a top-level `setq` that sets several;
- an entry of `custom-set-variables` (custom.el);
- an entry of a `use-package` form's `:custom`.

It refuses, and says why, when:

- your Lisp sets the variable in more than one place (drgnx would not know which one to take);
- the line runs only sometimes (inside `when`, `unless`, `with-eval-after-load`, a hook, a deferred `use-package`):
  moved, it would always apply;
- the value is computed, such as `(expand-file-name "notes" "~")`: only a value written as it is can move;
- where the value comes from is not certain (the line is unknown);
- the value in effect would change: something after your line sets the variable, a value Customize saved would win
  over the new entry, or a `setq` sets only the buffer it ran in.

Before anything changes you see the diff of both files and the value in effect now and after; nothing is written
unless you say yes. Then the entry goes into `settings.el`, and your line is replaced by a comment:

```elisp
;; fill-column: moved to Settings (2026-10-24)
```

A copy of your file from before is kept beside it (`config.el.bak-DATE`, the newest three), and **Settings: Undo Move**
puts both files back as they were. Undo refuses when either file changed since the move, and names the copy.

**Settings: Move to My Lisp…** does the opposite: the entry of `settings.el` becomes `(setopt VAR 'VALUE)` at the end
of `config.el` (with a prefix argument, a file of yours you choose), under a comment line, and the entry goes. It
refuses when the entry is not the value in effect (moved, your Lisp would change it). The same preview, copy and Undo.

Both commands write your file in one step (a temporary file renamed over it), never while it has unsaved edits in a
buffer (an open buffer with no edits is reverted), never a file that does not read to its end, and only after
checking that nothing but the one form, pair or entry differs. Undo remembers this session's last 20 moves.

## Bringing an existing init.el (Task 29)

`drgnx-user-lisp-files` (a setting in `settings.el`) is your own list of Lisp files, loaded in order after
`config.el`: `(("~/.emacs.d/init.el" :on t) ("lisp/extra.el" :on nil))`. A file is relative to your config folder or
absolute, and is never copied.

- **On and off.** `t` on the Lisp files page (or **Settings: Turn a Lisp File On or Off**) turns the file of the line
  on or off. Turning one **on loads it now**. Turning one **off takes effect at the next start**: code that already ran
  cannot be unloaded, and the row says so. `config.el` and `custom.el` have the same switch (list them with
  `:on nil`); `drgnx safe` loads none of these files.
- **Settings: Add Lisp File…** (`a` on the page) adds a file, for example `~/.emacs.d/init.el`, without copying it. First
  it shows what it finds: changes to `custom-file`, `user-emacs-directory` or `package-enable-at-startup` (drgnx keeps
  the last two as they are for its own start), every use of `user-emacs-directory` and `locate-user-emacs-file` (an
  init.el that expects `~/.emacs.d/`), and a `package-initialize`, straight.el or elpaca bootstrap. Nothing is
  blocked; `drgnx doctor` names the bootstrap, because drgnx manages packages itself (`drgnx sync`).
- **Its early-init.el.** If an `early-init.el` sits beside the file, drgnx offers it as an **early file**
  (`:early t`): it loads at the end of drgnx's own `early-init.el`, before drgnx starts. drgnx's early settings stay.
  An early file's load time and errors appear on the page and in the notices once drgnx is up. An early file added
  while drgnx runs loads now.
- **`:emacs-dir DIR`.** By default `user-emacs-directory` is not changed for your file. When it uses it, you are
  offered **load it with its own folder as `user-emacs-directory`**: the variable is bound to `DIR` while that one file
  loads, so `(locate-user-emacs-file "lisp/x.el")` finds `DIR/lisp/x.el`. The caveat is written in the row: a `setq`
  of it in the file is undone afterwards, and what loads later (packages, other files) sees drgnx's folder.
- **`drgnx bisect`** takes the listed files that are on, `config.el` and `custom.el` as candidates beside the modules
  (in the copy, they are turned off by this setting) and names the file that breaks.

## Keeping custom.el tidy (Task 30)

## Packages' settings (Task 31)

## Moving from the old files

Before `settings.el`, drgnx kept its own settings in six files of the config dir: `agents.eld`, `ai.eld`, `keys.eld`,
`modules.eld`, `large-files.eld` and `session.eld`. The first start of a drgnx with Settings moves them into
`settings.el`, once:

1. Each file is read as drgnx reads it today, and each key becomes an entry: `:profiles` of `agents.eld` becomes
   `drgnx-agents-profiles`, `:layers` of `keys.eld` becomes `drgnx-keys-layers`, and so on (`drgnx-AREA-KEY`;
   `modules.eld`'s `:theme` becomes `drgnx-look-theme`). A comment above a key, or at the end of its line, goes
   above its entry. A comment inside a value, or outside the keys, is not carried; the old file keeps it.
2. `settings.el` is written once, then read back, and its values are compared with the old files'. If anything
   differs, `settings.el` is removed again, nothing moves, and a notice says so: drgnx keeps reading the old files.
3. Then each old file is copied to `<state>/backups/migrated-YYYY-MM-DD/` and moved to
   `<config>/migrated-YYYY-MM-DD/`. That folder is in your config dir, so it travels: another machine's git sees the
   move.
4. One notice says "Your settings moved into settings.el (N files)", with **Show Report**.

This happens only while `settings.el` does not exist. A start after a crash between steps 2 and 3 finds
`settings.el` and never moves anything again; the doctor's `settings-migrated` line then names the old files
("already migrated") and **Settings: Move Old Files Away** moves them, with a copy, when `settings.el` holds the same
values. One that differs stays.

- **A file with a mistake is not moved.** Nor is one with keys this drgnx does not know, or one a newer drgnx wrote.
  It stays where it is, and the report says why. drgnx no longer reads it (its settings live in `settings.el` now),
  so you are told: a notice at every start and the doctor's `settings-migrated` line name the file and why, until it
  is fixed and folded in.
- **`keys.eld`'s `:layers nil`** means "drgnx's default stack", so it gets no entry.
- **Settings: Migration Report** shows each old key and its setting at its line in `settings.el`, what stayed and
  why, and the `custom.el` entries Settings could hold (Tidy moves those). The report is kept in
  `<state>/settings-migration.eld`.
- **Settings: Migrate Old Files** runs the move now while `settings.el` does not exist. Once it exists, it takes a
  file that stayed and that you fixed: its values go into `settings.el` for the settings that have no entry there yet
  (an entry you have is never changed), and the file moves away when `settings.el` holds all of them. Comments in the
  old file stay in the moved copy.
- **Two machines.** Move on one machine first: commit and push your config dir before you start drgnx on another
  machine, and pull there first ([second-machine.md](second-machine.md#moving-to-settingsel-on-two-machines)).
- **Untouched:** `config.el`, `custom.el`, `projects.eld`, `layouts.eld`, `packages.eld`, the lock and the state
  files. A project's `.drgnx/*.eld` files are in its repository and never move by themselves.
- Until each part of drgnx reads its settings directly, code that asks for the old files' values gets them from
  `settings.el`. Safe mode reads your keys from there too.

## Keys, modules, large files and the session (Task 16)

These four read and write their settings directly now:

| Old file | Settings | Applies |
|---|---|---|
| `keys.eld` | `drgnx-keys-layers`, `-pending-layers`, `-bind`, `-unbind`, `-mac-option`, `-tty-fallback` | at once: the keys are bound again |
| `modules.eld` | `drgnx-modules-disabled`, `-enabled`, `-flags`, `-external`; `drgnx-look-theme` (from `:theme`) | at once: a module is turned off with its teardown or on again; the theme switches |
| `large-files.eld` | `drgnx-large-files-ask-above`, `-chunks-above`, `-chunk-size` | read when a file opens |
| `session.eld` | `drgnx-session-keep-running` (also named `drgnx-keep-running`) | read when a window closes |

- The Keyboard Shortcuts editor, Keyboard Profile…, Preferences: Modules, Color Theme, Keep drgnx Running and
  Onboarding write `settings.el` through the settings writer: only the entry that changes, your comments and the rest
  of the file stay (a comment inside the value they rewrite, such as within the `drgnx-keys-bind` list, goes, as
  [Comments](#editing-by-hand) says). They refuse a `settings.el` that does not read, or an entry of these settings that does not fit,
  and change nothing.
- A `setq` of one of them in `config.el` counts too: at the end of the start drgnx applies it (a module you put in
  `drgnx-modules-disabled` there is turned off).
- These settings are global. A workspace file may not set the keys, the modules or the theme (they run code or change
  what drgnx does everywhere), and an agent may not change them. A project's `.drgnx/large-files.eld` still lowers the
  two large-file sizes.
- An old file that stayed because it had a mistake is **not read any more** for these four (a notice and the doctor
  name it): fix it, then **Settings: Migrate Old Files**, or set the values in `settings.el`.
- Safe mode applies your keys from `settings.el` (drgnx's own entries), as before.

## Safe mode and Turn Off Package Settings

drgnx's own settings (keys, agents, the sandbox, trust, the modules you turned off) always apply. The rest of
`settings.el` — values for packages and for Emacs itself — can be set aside:

- **`drgnx safe`** applies only drgnx's own entries of `settings.el`. Package and Emacs entries wait, and no module
  runs.
- **Settings: Turn Off Package Settings** takes every package and Emacs value of `settings.el` out of Emacs now. Each
  variable goes back to what it would be without `settings.el` — unless your Lisp set it since, in which case your
  value stays. **Settings: Turn On Package Settings** applies them again now, by the same rule as a change in Settings:
  where your Lisp or Customize set a variable since, their value stays. Both act at once; nothing restarts. Off lasts
  until you turn it on, or until the next start.
- **Per-language values** follow the same rule: in safe mode and while package settings are off, a buffer opened gets
  only drgnx's own settings from its `(:mode …)` sections. A buffer already open keeps what it got.
- **`drgnx bisect`**: when a problem still shows with every module off, it tries once more with package settings off
  and tells you when `settings.el`'s values are the cause.
- Loading `settings.el` by mistake (`emacs -Q -l settings.el`) changes nothing: it stops at its first word,
  `drgnx-settings`, before any value is read.

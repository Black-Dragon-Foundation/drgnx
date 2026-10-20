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
core/drgnx-ui-kit.el  the UI kit: glyphs by meaning, status faces (the UI kit section)
core/drgnx-session.el  drgnx PATH's Emacs side, Open Folder…, keep running or quit, Quit drgnx; session.eld is a config file (../guide/opening.md)
core/drgnx-macos.el  the drgnx app on macOS (drgnx macos-app; ../guide/opening.md)
core/drgnx-tty.el    terminals, batch-safe: which one, what it can do, keys it can send, terminfo, tmux (../guide/terminal.md)
core/drgnx-tty-recommend.el  a terminal that sends every key: installed ones, the install command per OS, the opt-in opener
core/drgnx-tty-fallback.el   keys a legacy terminal cannot send: their Alt+Shift and F6 forms, drgnx-tty-sendable-key (the layer: modules/ui/drgnx-tty-fallback-layer.el)
core/drgnx-file.el   files drgnx keeps: the bounded reader, the atomic writer, the locked update, backups (below)
core/drgnx-shell-env.el  PATH, MANPATH, INFOPATH from the login shell, once per start, asynchronously; never a key;
                     the hub follows (env/set); Shell: Reload Environment (../guide/shell.md)
modules/<category>/drgnx-<name>.el   one drgnx-module-define per file
```

## Paths (`drgnx-paths.el`)

`drgnx-dir` is the checkout (code only, never written to). Every other folder comes from one rule,
`(drgnx-paths-dir KIND)` for KIND `config`, `state`, `cache` or `data` (a directory name ending in `/`; the table is in
[files.md](../guide/files.md#where-drgnx-keeps-its-files)). `bin/drgnx-paths.sh`'s `drgnx_dir KIND` is the same rule in
bash: `bin/drgnx` sources it, and `install.sh` carries a byte-identical copy between its `# >>> drgnx-paths.sh` and
`# <<< drgnx-paths.sh` lines (curl pipes it, so it cannot source a file); `drgnx-paths/matrix-elisp-and-bash-agree`
and `drgnx-bin/install-carries-drgnx-paths` keep the three equal (the matrix runs bash a second time with
`BASH_COMPAT=32`, macOS's bash 3.2 rules). Only a value that begins with `/` counts
(`drgnx-paths-env-dir`): unset, empty, relative and `~/…` mean the default. Nothing is memoized (env/set changes the
variables). Compatibility: with `$DRGNX_CONFIG_DIR` unset, no `$XDG_CONFIG_HOME/drgnx` and an existing
`~/.config/drgnx`, the config dir stays `~/.config/drgnx/`; `(drgnx-paths-config-moved-p)` then returns where it
belongs, and the doctor's `config-dir` check warns. `(drgnx-user-dir)`, `(drgnx-state-dir)`, `(drgnx-cache-dir)` and
`(drgnx-data-dir)` are one-line wrappers. The data dir holds `elpa/`
(the packages every session uses), `generations/` and this machine's files that must not travel (`emacs`,
`systemd/`, `applications/`: [second-machine.md](../guide/second-machine.md)); `(drgnx-package-cache-dir)` keeps downloaded package files
([packages.md](../guide/packages.md)).
Every helper expands with `default-directory` bound to `"/"`, so a `~` is always the local home: in a remote
buffer (a Tramp `*scratch*`, dired over ssh) a timer, hook or save never makes Tramp contact the host;
`drgnx-paths-dir` also binds `file-name-handler-alist` to nil, so even a variable that looks remote is a local name, as in bash.
Started with `--init-directory <checkout>/init`, Emacs keeps its own state (`user-emacs-directory`: auto-save list,
histories) in `(drgnx-state-dir)emacs/` and native code in `(drgnx-cache-dir)eln-cache/` (`init/early-init.el`), so
nothing is written into the checkout; a harness session keeps both in its run directory. `custom-file` is
`(drgnx-user-dir)custom.el` (set and made when missing by early-init, loaded by `drgnx-init` once the packages are activated and guarded, as
config.el is: an error is said, `drgnx safe` skips it): Customize and `package-install` save there,
never into the checkout's tracked `init/init.el`.

## Files drgnx keeps: drgnx-file (`drgnx-file.el`)

One reader and one writer for every file drgnx keeps. It requires only `cl-lib` and `subr-x`, so an
`emacs --batch -Q` hub loads it. Every name is used with no file name handlers and `default-directory` `"/"`:
nothing here reaches Tramp, and nothing prompts or visits a buffer. Errors: `drgnx-file-refused` (data
`(FILE REASON)`) and `drgnx-file-busy` (data `(FILE HOLDER)`), both `file-error`s.

**Which call.** Config files go through drgnx-config, which uses this layer. State files change through
`drgnx-file-update` with `:on-unreadable 'backup`. Reports and other files rewritten whole use `drgnx-file-write`
with `:fsync nil`. Text files drgnx writes (unit files, desktop entries, exports) use `drgnx-file-write-text`.
A state file whose content grants something falls back to granting nothing: trusted-folders.eld
(`core/drgnx-trust.el`) trusts no folder when it is unreadable, has a mistake or has a newer `:version`, and its
writer (`drgnx-trust--write`) backs up the first two and refuses the third (`user-error`), since `:on-unreadable
'backup` covers only a file that does not read. Its reader also drops remote entries and those Trust This Folder
refuses (`drgnx-trust--read-entry-p`: `file-remote-p` only parses, and the truenames are taken with no file name
handlers, so a read at startup or from the palette never connects; an entry that signals is dropped), and messages
once per change of an unusable file. The mode body reads under `condition-case`, so a bad file never keeps a guard
off. Untrust This Folder takes effect in the session (`drgnx-trust--added`) even when the file cannot be changed.

The report files in the state folder go this way: `wb-report.eld` (`drgnx-rules--write-report`, a startup hook: an
error becomes one `message`), `agent-checks.eld` (`drgnx-agent-check-remember`, `:private t`) and `check/durations.eld`
(`drgnx-check--save-durations`) and `terminal-report.eld` (`drgnx-tty-frames--save-report`, from a terminal frame's
hooks: an error goes to `drgnx-hooks-problems`) are written with `drgnx-file-write ... :fsync nil`, so a failed write
keeps the old report. They are read with `drgnx-file-read`: `drgnx-tty--read-report` (which ui/terminal's
`drgnx-tty-frames--read-report-data` calls too), `drgnx-agent-check-results`,
`drgnx-check-durations` and the doctor's `drgnx-doctor--state-file` / `drgnx-doctor--keys-report` give the data of an
`ok` file, else nil (missing, over 1 MiB, a mistake, text after the form, not plain data). A report is rebuilt by its
next run, so a report with a mistake is not kept aside.

**job.eld.** A durable job's `jobs/ID/job.eld` is a plist of plain data in one form: `drgnx-jobs-start` writes it with
`drgnx-file-write` (text properties on the name and command are dropped first), `drgnx-jobs--read` reads it with
`drgnx-file-read` (nil for a missing or unreadable file), and the stamp (`drgnx-jobs--stamp`: `:boot` and `:start`) is
`drgnx-file-update` with `:timeout 0` from the poll, `1.0` from `kill-emacs-hook`, `inhibit-interaction` bound; a `:start`
already stamped within 0.5 s of the process's is kept (Emacs's reading of it jitters by a clock tick). A busy lock
skips the stamp; an unreadable job.eld is left alone and the error becomes one `message`; the stamp never creates a
missing job.eld or its directory. Files written by older versions (one `prin1` form) read unchanged.

**Reading.** `(drgnx-file-read-bounded FILE &key max-bytes)` gives the file's text decoded as UTF-8, or nil when it
does not exist. It refuses, in this order:
- a remote name (`/method:host:…`): "a remote file";
- a symbolic link to nothing;
- anything that is not a regular file, checked by the mode string before opening, so a FIFO never blocks
  (`file-attribute-type` is nil for a FIFO as for a file);
- a file over `drgnx-file-max-bytes` (1 MiB), also one that grew past it while it was read. It is never truncated.

A file swapped for a FIFO between the check and the open would still block: Emacs cannot open without blocking.

`(drgnx-file-read FILE &key max-bytes)` gives `(:status S :data D :text T :problem P :stamp ST)`:
- S is `absent` (missing, empty, or only whitespace and comments), `ok` or `unreadable`.
- It reads exactly one form with `read-circle` and `read-symbol-shorthands` nil. These are problems: `#1=`, text
  after the form, lists or vectors nested deeper than `drgnx-file-max-depth` (64), and any object other than a
  symbol, a number, a string without text properties, a cons or a vector (records, `#s(hash-table …)`, byte-code,
  bool-vectors, char-tables).
- P is `(:text STRING :line N :column N)`, both 1-based. A refusal of the bounded read is a problem at line 1.
- ST is `(drgnx-file-stamp FILE)`: `(INODE MTIME SIZE)` of the truename from one `file-attributes` call. The inode
  sees a file renamed over another within one mtime tick. The stamp is taken before the read, so a change in between
  shows as a change at the next compare.

**Writing.** `(drgnx-file-write FILE DATA &key header mode private (fsync t) pretty text max-bytes)` returns the path
written:
- Content over MAX-BYTES (default `drgnx-file-max-bytes`, the read limit) is refused ("over N bytes") before any
  temp file is made, so drgnx never writes a file its own reader would refuse. A file that grows passes a larger
  limit, to its reads too.
- It writes to FILE's truename, so a symlink stays a symlink, and makes missing folders. A non-regular file there is
  refused.
- The content goes to a temp file `.NAME.tmp-XXXXXX` beside the target (made 0600), which is renamed over it. A
  reader sees the old file or the new one, never half of one. An error before the rename leaves the old file and
  deletes the temp file.
- The mode is the old file's, else MODE, else 0644. With PRIVATE it is 0600 for a new file, and an old file loses its
  group and other bits.
- The content is HEADER (comment lines), then TEXT when given, else DATA printed by `prin1` (`pp` with PRETTY) with
  `print-length`, `print-level`, `print-circle`, `print-integers-as-characters` and `float-output-format` nil, in
  UTF-8. A user's `print-length` never shortens a file.
- The temp file is read back by `drgnx-file-read`'s rules and must be `equal` to DATA, else the write is refused
  ("not printable as data") and the target is untouched. A buffer object, a hash table or a TEXT that is not DATA
  never reaches the file.
- FSYNC binds `write-region-inhibit-fsync` to nil. No lock file is made, and no buffer visits the target, so one that
  visits it is never modified or asked about.

`(drgnx-file-write-text FILE TEXT &key mode private (fsync t))` writes text with the same rules, no read back and no
size limit: reports, units and exports are not read back through the bounded reader.
The text files drgnx writes all use it: the markdown export (`drgnx-surfaces-export-markdown`: an old file keeps its
modes, a new one gets 0644), the systemd unit (`drgnx-pkg-service-unit`), the Linux desktop entry, the `config.el`
template (made only when the file is missing) and the agents' settings files and their backups (below).

**The locked update.** `(drgnx-file-update FILE FN &key on-unreadable (timeout 1.0) max-bytes header pretty render)`
takes the lock, reads the file fresh, and writes `(FN DATA)`. FN gets a deep copy of the data, so a `plist-put` in
place is a change like any other, and nil for an absent file. When FN's result is `equal` to the data, nothing is
written. MAX-BYTES limits both the read and the write. RENDER, when given, is called with the old text, the data as
read (untouched by FN) and the new data, and returns the text to write (a surgical edit that keeps comments). The
lock is released in `unwind-protect`.
- An unreadable file is refused (`drgnx-file-refused` with the problem) and left untouched.
- With `:on-unreadable 'backup` (state files only), it is copied aside first and FN gets nil.
- A write from a timer, filter or sentinel passes `:timeout 0` and skips the write on `drgnx-file-busy`. The site's
  next run writes.

**The lock** is the directory `.NAME.lock/` beside the truename. `make-directory`, without parents, decides who holds
it. Its `owner` file holds `(:pid :host :started :time)`. `(drgnx-file-lock-holder FILE)` reads it.
- An attempt is made every `drgnx-file-lock-retry` (10 ms) up to TIMEOUT. With TIMEOUT 0 there is one attempt.
  Then `drgnx-file-busy` names the holder. It never prompts.
- A lock is stale when its `:time` (or, with no owner file, the directory's mtime) is older than
  `drgnx-file-lock-stale` (10 s). It is also stale when it is on this host and its pid is gone or started at
  another time (`:started` compared within 1 s), so a reused pid is not taken for the holder. Where Emacs cannot
  tell a process's start time, only the age counts.
- A stale lock is renamed to `.NAME.lock.stale-PID-RANDOM` and deleted, then `make-directory` decides again. A lock
  is released only while its owner file is still the holder's.
- **Limits.** Two processes stealing one stale lock within milliseconds can both hold it: the second renames the
  first's fresh lock away. Plain files cannot compare-and-swap; the search index's lock takeover has the same
  limit. A holder that keeps the lock over 10 s loses it, so FN must stay a quick change of data. A call to
  `drgnx-file-update` inside FN on the same file waits for itself and ends busy. On a network filesystem the
  rename and `make-directory` are only as atomic as the server makes them.
- The clock and the wait go through `drgnx-file--now` and `drgnx-file--sleep`, which tests replace.

**Backups.** `(drgnx-file-backup FILE)` copies the file to `NAME.bak-YYYYmmdd-HHMMSS-mmm` (UTC, so the names sort in
time order) beside its truename, keeping its times and mode. Then it keeps only the newest
`drgnx-file-backups-kept` (3). It gives the backup's path, or nil for a missing file, and refuses anything that is
not a regular file.

## Schema (`drgnx-schema.el`)

One DSL describes drgnx's data (config files today; the hub's parameters and results next). A schema is data: an atom
or a list. `(drgnx-schema-check SCHEMA VALUE)` returns nil, or `(PATH . TEXT)` for the first problem. PATH lists the
plist keys, alist keys and list indices from the top, e.g. `(:profiles "local" :command 0)`. It walks the schema, not
the data, tests every list with `proper-list-p` first (an improper or circular list is a problem, never an error)
and never quotes the value in TEXT (it may be a token). A schema that is not one signals
`(error "drgnx-schema: unknown form …")`: that is the definition's bug, so it is an error, not a problem. A PATH holds alist and map keys taken from the value (fine for ids); a problem's TEXT never does.
`(drgnx-schema-validate SCHEMA)` finds those bugs when a schema is defined rather than when data reaches it: heads, options and their value types, plist entries, `pred` arguments, bound named types, and a type that refers to itself with nothing in between. `drgnx-schema-deftype` calls it (a refused type leaves the table as it was); the config layer's and the hub's definition forms call it too. A type may name itself only inside a container.

| Form | Accepts |
|---|---|
| `any` | anything (hub: results only; see `drgnx-schema-uses-form-p`) |
| `symbol` / `keyword` | a non-nil, non-keyword symbol / a keyword |
| `string`, `boolean`, `null` | a string / `t` or `nil` / `nil` |
| `integer`, `natnum`, `number` | an integer / an integer >= 0 / any number except NaN |
| `(integer :min N :max N)`, `(number :min N :max N)` | the same within the bounds |
| `(string :max N :match RE)` | a string at most N long that matches RE (case-sensitive, unanchored: write `\\``…`\\'`) |
| `(enum V…)` | a member (`member`, so strings work) |
| `(or S…)` | a value that fits one of the schemas (`(or null S)` reports a problem inside S at its own path) |
| `(list-of S [:max N])` | a proper list of S |
| `(plist (KEY S [DOC] [:required t])…)` | an even proper list of keywords and values; no key twice; required keys present; **unknown keys are allowed** and a value under one is not walked |
| `(alist KEY-S VAL-S)` | a proper list of conses, no key twice (`equal`) |
| `(map VAL-S [:max N] [:keys KEY-S])` | a JSON object whose keys are not fixed: a keyword plist (how the hub decodes JSON) or an alist with string keys; at most N entries, no key twice. Keys are named without the colon in the path and to KEY-S |
| `home-path` | absolute, `~` or `~/…`; no NUL; not a remote name (`/ssh:host:…`) |
| `https-url` | `https://` and a host; no user info, query, fragment, blank or control character (as bootstrap; a use that needs a query makes its own `pred` type) |
| `(pred FN DOC)` | `(funcall FN VALUE)` non-nil. An unbound FN, or one that signals, **fails** (never passes); DOC is the problem's text |
| NAME | a type made with `(drgnx-schema-deftype NAME SCHEMA DOC)` (redefinable; the built-in names are not) |

Also: `(drgnx-schema-unknown-keys SCHEMA VALUE)` lists the PATH of every unknown key in every plist the schema reaches
(what the config layer reports and keeps byte for byte); `(drgnx-schema-describe SCHEMA)` gives rows
`(PATH TYPE-TEXT DOC REQUIRED)` for the generated reference (`*` in a PATH stands for any alist or map key and any
list element); `(drgnx-schema-uses-form-p SCHEMA FORM)` says whether a form occurs at any depth, through named types
(the hub refuses a `:params` schema holding `any`).

**There is one DSL.** Design 2 (the hub protocol: parameter schemas, JSON Schema for MCP) adds the forms it needs to
this file and derives its JSON Schema output from the same schema data; it does not define another. `number`, `map`,
`natnum` and `any` are here for it.

## Config files: drgnx-config (`drgnx-config.el`)

Every config file drgnx keeps has one definition, and is read, applied and written through this layer. It requires
only `cl-lib`, `subr-x`, `drgnx-paths`, `drgnx-file` and `drgnx-schema`, so the `emacs --batch -Q` hub loads it.

**Define.** `(drgnx-config-define NAME &key file dir shape version schema default reload last-good max-bytes migrate
header doc)` returns NAME:
- `:dir` is `config` (`drgnx-user-dir`, the default), `state` (`drgnx-state-dir`) or `project` (`ROOT/.drgnx/`:
  untrusted, read-only, no last good copy, 64 KiB).
- `:shape` is `plist` (the default) or `alist`, and the `:schema`'s head must be the same. The schema is validated
  when the file is defined (`drgnx-schema-validate`).
- `:version` is the format this drgnx writes (1). `:reload` is `mtime` (the default: a get costs one stat, and a
  changed file is applied at once) or `start` (read at the first get, then only on `drgnx-config-reread`). Use
  `start` only where applying a change mid-session is unsafe.
- Code outside the layer never touches `drgnx-config--` names. It asks: `(drgnx-config-defined-p NAME)`,
  `(drgnx-config-definition NAME)` (the definition plist, read only) and `(drgnx-config-names &optional DIR)` (sorted;
  DIR is `config`, `state` or `project`, or a list of them). `(drgnx-config-ensure-writable NAME &optional ROOT)` is
  the pre-flight for a flow that ends in a write: it reads the file fresh and signals `drgnx-config-refused` when it
  has a mistake or is newer, so call it before the flow's first side effect (Import, Save Layout As…, a settings page
  that asks questions first) and a refusal changes nothing.
- A project file is untrusted data: it is read, never evaluated. `search-project` (`.drgnx/search.eld`, in
  `core/drgnx-search-chunk.el`) is the first: `drgnx-search-config` asks `drgnx-config-problem` and turns a mistake into
  `(:error …)`, because a search must fail closed rather than fall back to the defaults the layer applies.
- `:last-good` (t) applies the last good copy on a mistake. `:max-bytes` (1 MiB) caps reads and writes.
- `:on-mistake` is a string saying what happens instead of using the file when it is not the last good copy or the
  defaults ("drgnx sync stops until it is fixed; nothing is changed"). The mistake notice and the reference's "On a
  mistake:" line print it; a project file with none is said to be refused.
- `:migrate` is `((FROM . FN)…)`; `:header` is the comment a new file starts with (default
  `;; drgnx: FILE (docs/reference/config.md)`); `:doc` is one line for the reference.
- Open Config File… visits the file with a buffer-local `after-save-hook` that reads it again (`drgnx-config-reread`),
  so a hand fix clears the notice at once. Listeners of `drgnx-config-changed-functions` see
  `drgnx-config-user-save` t then, and keys.eld's (`drgnx-keys--config-changed`) re-applies the keys; drgnx's own writes
  do not set it, as they apply what they write.
- Defined in a module's setup, it is undone at teardown: the previous definition comes back, or NAME is undefined,
  unless NAME was defined again since. Core files define theirs at load. `(drgnx-config-undefine NAME)` takes one
  out. `drgnx-config--defs` is in the teardown census.

**Get.** `(drgnx-config-get NAME &optional KEY ROOT)` gives the applied value, or KEY's value in it. A KEY the file
does not have (not `plist-member`, not `assoc`) gives the default's. The value is shared: do not change it. A file
is applied when it is `ok`, `newer` or `migrated`; an absent file applies `:default`. `(drgnx-config-read NAME
&optional ROOT)` reads fresh and applies nothing: `(:status :data :problem :version :unknown-keys :file :stamp)`.
`(drgnx-config-file NAME &optional ROOT)` is the path. When a re-read (or our write) changes the applied value,
`drgnx-config-changed-functions` runs with NAME (no prompts, each function guarded). Code that draws from a value
caches it and listens there instead of getting it per redisplay.

**The fallback.** A file with a mistake is never applied, in whole or in part. Its last good copy is, when
`:last-good` is t and the copy still reads well; else the default. Last good copies are kept per machine in
`<state>/config-good/NAME.eld`, written when a good read has a new stamp and its text differs. A mistake is one
problem: `(drgnx-config-problem NAME &optional ROOT)` gives `(:name :file :text :line :column)`,
`(drgnx-config-problems)` every current one (from what was applied, no I/O). Each mistake is said once: one
`*Messages*` line ("drgnx: FILE: TEXT (line L) — using its last good copy", or "the defaults") until design 5's
`drgnx-notify` exists, then a `fail` condition of the `config` source.

**Versions.** A plist file's `:version` is its format; a missing one means 1, and an alist file is always 1. The
rule for authors: **add a key, never change one.** Unknown keys are kept, so a new key needs no new format. Bump
the version only for a change of shape or meaning, and add a `:migrate` step from the old one.
- An older file is migrated in memory and applied (`migrated`). Only a user's write, or Migrate Config File…, writes
  it back: the old file is backed up first (`NAME.bak-…`), and the new one gets this format's `:version`. Nothing
  automatic writes a version change, so a machine that only starts never migrates a shared folder.
- A newer file is applied when it fits our schema (`newer`), and is read-only here. One that does not fit is a
  mistake.
- A plist file whose first element is not a keyword is format 0: only a definition with a `(0 . FN)` step reads it.

**Writers.** `(drgnx-config-set NAME KEY VALUE &optional ROOT)`, `(drgnx-config-unset NAME KEY)` and
`(drgnx-config-update NAME FN &key root (timeout 1.0))` return the new applied value. Each is a
`drgnx-file-update`: the lock, a fresh read, FN on the data (migrated when the file is older; nil when it is absent,
not the default), the write.
- They refuse a file with a mistake and a newer one with `drgnx-config-refused` (a `user-error`, and a `file-error` so its text prints without quotes; a handler for
  `file-error` catches it too), and leave it as it
  was: "FILE has a mistake at line L: TEXT — fix it (Preferences: Open Config File…) or reset it; it was not
  changed", or "FILE was written by a newer drgnx (format V; this one writes W): update drgnx here; …". A project
  file is read-only (an `error`).
- FN's result must fit the schema, else an `error`: it is the caller's bug. A result `equal` to the data writes
  nothing.
- **The surgical render.** Only the top-level plist keys or alist entries (keyed by their `car`) that changed are
  touched in the text. A changed one has its value (or entry) replaced, printed with `prin1`, or `pp` indented to
  its column when it is wider than 70 columns. A removed one goes with its blanks up to the next item (the last one
  takes the blanks before it). A new one goes after the item before it in the new data, past that item's own
  comment, else first. Comments, layout and unknown keys stay byte for byte; **comments inside a replaced value are
  lost.** Items keep their places: a result that moves items the file has is an `error`, never a rewrite of the
  whole file. An absent file gets the header and the data pretty-printed, `:version` first for a plist. The write's
  read-back (`drgnx-file-write`'s `:text` check) refuses a text that does not read back as the new data.
- From timers, filters and sentinels, pass `:timeout 0` and catch `drgnx-file-busy` (the next run writes).
- **A whole text.** `(drgnx-config-write-text NAME TEXT &key expect-stamp (timeout 1.0))` is for an editor that holds
  the file's whole text and changes it its own way (the keys editor): it replaces the file by exactly TEXT, under
  the lock, through `drgnx-file-write-text`, and returns the new applied value. TEXT must read, fit the schema, be no
  newer than this drgnx writes and fit the size limit, else `drgnx-config-refused` names the line ("the new text of
  FILE has a mistake at line L: …; it was not written"). EXPECT-STAMP is `drgnx-file-stamp` of the file as the
  editor read it (nil: it was absent); when it is given and the file's stamp is not `equal` now, the write is
  refused: "FILE changed since you opened it; nothing was written". Given, a file that has a mistake may be written
  over (the editor showed it); without it a file with a mistake is refused, as the other writers do. A file a newer
  drgnx wrote is refused either way.

**Commands** (Preferences, in the palette): Open Config File… (`drgnx-config-open`, at the mistake's line and column),
Reset Config File… (`drgnx-config-reset`: asks, keeps a backup, writes the header and the default; refused in batch;
`drgnx-config--reset` does it without asking) and Migrate Config File… (`drgnx-config-migrate`, for a `migrated`
file). The name is completed over the defined files, those with a mistake first.

**Tests** load `test/fixtures/config-fixture.el`. `(drgnx-test-with-config BODY…)` points the config and state
folders at a fresh temp root (`drgnx-test-config-root`), and sets the definitions, the applied state, the problems
said and `drgnx-config-changed-functions` back afterwards. `(drgnx-test-config-put NAME TEXT &optional ROOT)`
replaces a file as an editor would (a new inode, so its stamp changes), and `(drgnx-test-config-text NAME &optional
ROOT)` reads it.

**The packages' files** (`core/drgnx-pkg.el`, `core/drgnx-pkg-activate.el`; [packages.md](../guide/packages.md)):
- `packages` (`packages.eld`) is `:reload start`, read again (`drgnx-config-reread`) by `drgnx-pkg-manifest`,
  `-archives` and `-archive-priorities`, so each sync sees the file as it is. `lock` (`drgnx.lock.eld`) reloads on
  change. Neither has a last good copy: a mistake in either is a `drgnx-pkg-error` ("FILE has a mistake at line L:
  TEXT"), a sync stops before it changes anything, and nothing replaces the file. The lock's `:packages` entries are
  checked by `drgnx-pkg--lock-entry-p`. The schema is wider than the first sketch, so files that worked still do: a
  Git `:url` and an archive may be a path or an ssh address (strings), a priority any number, and `:rev` and
  `:lisp-dir` are known keys.
- The lock is written by `drgnx-config-update 'lock`: `drgnx-pkg-write-lock` replaces `:packages` (and takes out
  `:from-shipped`), so a comment or a key of the user's in the file stays. A sync checks `drgnx-config-ensure-writable`
  up front, so a lock a newer drgnx wrote stops it before the install. Rollback keeps a lock it cannot read or write
  in a `.bak-` copy before it puts the generation's lock back. The lock drgnx ships (`etc/drgnx.lock.eld`) is not a
  config file: `drgnx lock --ship` writes it with `drgnx-file-write`, and `drgnx-pkg--read-lock-file` checks it
  against the lock's schema.
- `generation.eld` is written with `drgnx-file-write` and `generations/current` with `drgnx-file-write-text`.
  `packages-wanted.eld` (a bare list of names, a state file) is changed with `drgnx-file-update … :on-unreadable
  'backup :timeout 0` from `drgnx-pkg--record-want`, which runs at startup: it never prompts or waits, skips a file
  another process holds (the next startup records the want), and turns an error into one message.

**The reference and the doctor.** `docs/reference/config.md` is generated from the definitions: for each, sorted by
name, its file, folder, format, reload rule, what happens on a mistake, its `:doc` and a table of its keys from
`drgnx-schema-describe`. A test fails when it is out of date, and prints the command. After a change to a definition
(or a new file), regenerate it and commit it with the change:

```sh
emacs --batch -Q -L core -L wb -L harness -L modules/tools -L modules/editor -l drgnx-config-doc \
  --eval '(drgnx-config-doc-regenerate "docs/reference/config.md")'
```

`drgnx-config-doc-regenerate` loads the sources (`drgnx-config-doc-load`) and then writes (`drgnx-config-doc-write`,
which does not load anything). Run it once in a fresh batch Emacs; a test runs this very command and compares.

`harness/drgnx-config-doc.el` finds the definitions through `drgnx-config-doc-sources`, one entry per line:
`(require FEATURE)` for a core feature that defines files at load, `(setup MODULE)` (after a `(require FILE)` for the
module's file) for files a module defines in its setup, run through `drgnx-modules--run-setup`. A port that adds a
definition appends its entry and regenerates. Every definition needs a `:doc` (a test checks).
The doctor's `config-files` check reads each non-project file fresh (`drgnx-config-read`, writing nothing), and the
core features that define files are listed in `drgnx-doctor-config-features`: a port appends its feature there too.
Tests: `test/unit/config-doc-test.el` and `test/unit/doctor-test.el`.

`onboarding.eld` (state folder, an alist of step → `(:status :message :time)`, `core/drgnx-onboard.el`) is the one
state file that is not refused when it cannot be read: `drgnx-onboard--record` is a `drgnx-file-update` with
`:on-unreadable 'backup` (the file is copied aside, the step is recorded in a new one), so two processes keep their
steps and a damaged progress file never stops onboarding. `drgnx-onboard-state` reads through `drgnx-config-get`;
`drgnx-onboard--write-state` (the Welcome's first-start marker) is a plain `drgnx-file-write`. Tests:
`test/unit/onboard-test.el`.

`face.eld` (state folder, a plist, `core/drgnx-face-state.el`) is a config file read by two programs: drgnx, and
`bin/drgnx`, which finds `:variant` and `:gtk-theme` in it with `sed` before any Emacs runs. So it is printed with `prin1`
on one line (a comment header on a new file names neither key), and the schema stays as wide as what M12f-a wrote:
no version key, unknown keys allowed. A change is `drgnx-face-state-put PLIST [TIMEOUT]` (sets those keys, keeps the
rest) or `drgnx-face-state-update FN`, both a `drgnx-file-update` with `:on-unreadable 'backup`: under the lock, on a
fresh read, nothing written when nothing changed, and a file that is unreadable or not a plist is copied aside to
`face.eld.bak-<time>` before it is started again. `drgnx-face-state-write` (replace the whole plist) stays for callers
that mean it. The theme hook passes TIMEOUT 0 and skips when `drgnx-file-busy`; a failure becomes one message.
`drgnx-face-state-read` is `drgnx-file-read`, never signals. Tests: `test/unit/face-state-test.el`.

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

`(drgnx-guard-automatic-p)` says whether the code running now is such a path, for code that would rather not ask
than signal (choosing a Vim stack records it as pending instead of offering to install evil).

## Notices (`drgnx-notice.el`)

One model for everything drgnx tells the user. Producers post; the chrome (status bar, cockpit, Notices list) and the
routes (echo area, desktop, the session file the doctor reads) read it. It is core and requires only `drgnx-guard`,
`drgnx-modules-record` and `drgnx-timer` (its clock, `drgnx-timer-now`: tests run it on `drgnx-test-with-clock`):
nothing in `wb/` or `modules/`, and it never calls UI.

**Severity and lifetime.** A notice's `:severity` is `info` (worth knowing), `warn` (degraded; drgnx works around
it) or `fail` (something you expect does not work); `ok` is only a check result. Its `:life` is:

- `event`: something happened. Kept in a ring of `drgnx-notice-event-limit` (200), oldest out.
- `condition`: something is wrong now, until its producer clears it. At most `drgnx-notice-condition-limit` (100)
  per source; past that, a new one only updates the source's `warn` condition `(SOURCE . more)`, "and N more", where N
  counts each id once, however often it is posted again. The source's own `(SOURCE . unknown)` is never held back.
- `attention`: something waits on your decision. Only a source's set makes these (below); their severity is
  `needs-you`.

**A notice** is a readable plist (it round-trips through `prin1` and `read`, so it can be written to disk) holding
only its non-nil keys: `:source :id :severity :life :text :detail :fix :command :scope :at :count :echo`.

- Its key is `(SOURCE . ID)`; an attention item's key is its ID alone, the entity you act on (`(card . 12)`).
- `:text` is one line: newlines become spaces and a leading `drgnx: ` goes.
- `:command` is a registry id, a command symbol or `(FN . ARGS)` with ARGS readable data — never a closure.
- `:at` is when that key first said that text. `:count` appears with the first repeat (absent means 1).
- `:echo`, when the producer passed it, is stored even when nil: `t` or nil overrides the echo rule, and nil on an
  attention item also keeps it off the desktop.

**The API.**

| Call | Does |
|---|---|
| `(drgnx-notify SOURCE SEVERITY TEXT &key id life detail fix command scope echo)` | Posts an event (the default) or a condition; returns its key. An event without ID uses its text, so the same text repeats as a count. |
| `(drgnx-notice-clear SOURCE &optional ID)` | Clears one notice, or all of SOURCE's events and conditions. |
| `(drgnx-notice-dismiss KEY)` | Hides an event or condition until it comes back with other text (also after a clear). An attention item cannot be dismissed: that signals. |
| `(drgnx-notice-set SOURCE ITEMS &key reason)` | Replaces SOURCE's whole attention set. ITEMS `:unknown`: see below. |
| `(drgnx-notice-define-source SOURCE &key title command stale)` / `drgnx-notice-undefine-source` | A module's own source. |
| `(drgnx-notices &key source severity life scope)` | Notices not dismissed, newest first (attention items too when LIFE is nil or `attention`). |
| `(drgnx-needs-you-count &optional SCOPE)`, `(drgnx-needs-you-items &optional SCOPE)`, `(drgnx-needs-you-unknown)` | The one "needs you" count, its items, the sources that cannot tell. |
| `(drgnx-problems-count)` | `(WARN . FAIL)`: conditions of those severities, not dismissed. |
| `(drgnx-notice-tick)` | Changes whenever the model does; memoise readers on it. |

The core sources (`drgnx-notice-core-sources`: `modules keys hooks commands bus guard hub config agents timers
terminal wb store render notice`) need no definition. A module defines its own in its setup; the definition pushes
its undo (`notice source SOURCE`), so turning the module off removes the source with its notices and its set. Any
other source is refused (`wrong-type-argument`), as are a severity or life outside the vocabulary (`attention`
included: only sets make those) and a `:command` that does not read back.

A **repeat** — the same key, text, severity and life — only counts: no tick, no hook call, no echo. Other text or
another severity at the key is a new notice (new `:at`) and lifts a dismissal.

**Sets and the union.** A source of things waiting on you sends its *whole* set whenever it learns it, so a lost
retraction cannot leave a stale item: `(drgnx-notice-set 'jobs (list (list :id (cons 'card 12) :text "j1 — Merge?"
:command '(drgnx-job-ui-show "j1") :scope "j1")))`. Items are plists with `:id` and `:text`, and optionally `:command
:scope :detail :echo`; a later item with the same ID wins, and an unchanged ID keeps its `:at`. Only a change of
ids or of what they say ticks: a source may send the same set every second. The model keeps ITEMS to compare the
next set with, so send fresh plists and do not change them afterwards. The needs-you count is the size of the
**union** of the sets, keyed by ID: an ask card that `jobs` and `questions` both hold counts once (the item with
the later `:at` shows; on a tie, the source defined first, core sources before all). `(drgnx-needs-you-count)` is
a cached integer; with a SCOPE (a job id) it is memoised until the next change. Neither allocates.

**`:unknown`.** A source that cannot learn its state (the hub went away, a recount failed) sends `(drgnx-notice-set
SOURCE :unknown :reason "…")`: its items drop out of the count and the `warn` condition `(SOURCE . unknown)` says
REASON (default "not known"), with the source's `:command`, until its next list clears it. A source defined with
`:stale SECS` that holds items and has not sent a set for SECS goes `:unknown` by itself ("not heard from in N
min"); this is opt-in, and no shipped source uses it. `drgnx-notice--check-stale` runs on every set and from the
session file's save timer.

**The `now` lane.** `drgnx-notice-functions` is called synchronously with each change, a plist `(:op OP :key KEY
:source SOURCE :notice NOTICE :added IDS :removed IDS)` holding only its non-nil keys, OP one of `post clear set
unknown dismiss undefine`. Each function runs inside `drgnx-automatic` with `inhibit-interaction`, so it cannot
ask. What a hook function may do: set a flag, `force-mode-line-update`, start a timer (`drgnx-timer-start`) for the
real work. An error is recorded in `drgnx-notice--hook-errors` (the last 20) with one `message` per function, and
never posted back into the model. A notice a hook function posts updates the model at once, but its own hook call
is queued and runs after the current one returns — never recursively; past 100 queued changes in one pass the rest
are dropped, with one message. The change plist is built only when the hook has functions.

**Cost** (allocation is the gate; `test/unit/core-notice-test.el`, byte-compiled): a count read 0 conses; a new
event 14 (22 with one hook function); a repeat 1 (its key). Replacing three sets of 40/40/20 items (80 ids) in
which three items change and three ids come and go, then reading the count, 250 conses (gated at 275; the wall
time, about 55 µs, is a perf number and not tested).

**Tests** use `test/fixtures/notice-fixture.el`: `(drgnx-notice-test-with-model BODY…)` starts BODY on an empty
model and sets the model it found back afterwards, variable by variable (`drgnx-notice-test--variables`), with
`set`; `drgnx-notice-test--alloc` counts the conses a byte-compiled body allocates (the fewest of 3 warm runs).

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

**Undefining.** `(drgnx-command-undefine ID)` removes a command from the table and the order (it returns ID, or nil
when there was none). A `drgnx-command-define` made by a module's setup pushes its own undo (see "Teardown" under Modules):
if the table still holds that very definition, the one it replaced comes back (keeping its bound keys and its place
in the order), or the command goes when it replaced none. Definitions of one id form a chain, so the undos are safe in
any order: tearing down the first of two modules that defined an id leaves the second one's entry alone and the second
one's teardown does not bring the first one back; a definition made outside a setup (a user's `config.el`) is never
touched. A library a setup `require`s registers for itself and stays until restart.

**How keys and menus follow.** The registry is the one source: after a batch of teardowns
`drgnx-modules-after-teardown-functions` runs `drgnx--after-teardown`, which calls `drgnx-keys-apply` (it puts back
Emacs's own bindings first, then binds what the registry still holds, so a removed command's keys are free again and
nothing a user bound is touched) and `drgnx-surfaces-refresh`.

## Surfaces (`drgnx-surfaces.el`, `drgnx-palette.el`)

Generated from the registry, never written by hand, showing the keys of the active key profiles: the menu bar,
right-click menus (contexts via `drgnx-surfaces-define-context`), which-key labels (when which-key is present),
the **key sheet** ("Keyboard Shortcuts", `*drgnx keys*`), a markdown cheat sheet (`drgnx-surfaces-export-markdown`), "next time:
KEY" tips after a command run from a menu or the palette, and the **command palette** (`C-S-p` in every profile): every available
command as "Category: Title" with its key and description beside it, through the normal completion UI.

**One key label.** `(drgnx-surfaces-key-label CMD-OR-ID &key context any short)` is the only function that turns a
command's key into text: the key sheet, the menus, the palette, the tips, the start page, the top line and the
Agents list's New Agent Session hint all call it.
CONTEXT nil gives the key as the selected frame's terminal can send it (`drgnx-surfaces--here`, applied once, so a
chord is never rewritten twice), `menu` the form that is right in every buffer (`drgnx-surfaces--always`), `plain` the key
as written (the markdown export). ANY falls back to `where-is-internal` when the profile binds nothing; SHORT drops the
" (in MAP)" suffix. It returns nil without a key; `drgnx-surfaces-key` is the wrapper that returns "" (PLAIN is the
context). `drgnx-surfaces-starter-commands` is the one list of the three keys everyone shows (Quick Open, the
palette, the key sheet) with what each does: the start page uses it as it is, the top line takes its ids and keeps
its own short labels.

**Run hook and usage counter.** `drgnx-surfaces-run` (what the palette and the menus call) runs
`drgnx-surfaces-run-functions` with the command id after the command ran; an error in a member is swallowed. The
first member counts the run: in memory only, so a run costs nothing noticeable. The counts are written at idle, at
most once a minute and at exit, never prompting (one idle timer under the key `surfaces-usage`, `drgnx-timer-soon`
with `:idle t`: a burst of runs makes one write per pause; the exit hook cancels it and writes), to `command-usage.eld` in the state dir
(`drgnx-shortcuts-usage-file`): `((ID COUNT (DAY . N)…)…)`, with the per-day counts (`time-to-days`) of the last 7
days. The file stays on your machine; it feeds the suggestions of the Keyboard Shortcuts editor ("you ran X 12
times this week; give it a key?"). Read it with `drgnx-surfaces-usage-count` and `drgnx-surfaces-usage-week`.
The file goes through the file layer: the write is `drgnx-file-update` with `:on-unreadable 'backup` and `:timeout 0`
(the exit write waits up to a second), so a busy lock (another drgnx writing) keeps the counts dirty and the timer tries
again, quietly. A file that cannot be read, or has malformed entries, is copied aside once (`NAME.bak-…`) before the next
write replaces it; any other failure is one message. The last writer wins.

**Removing what a command added.** The palette, the key sheet, the cheat sheet and the right-click menu are computed
from the registry on each use, so an undefined command is gone from them at once. The menu bar and which-key are
written, so they are undone explicitly. `drgnx-surfaces-build-menus` remembers what it added, per command id: the item
(a claim on its menu path and title, `drgnx-module--claim`, so two commands sharing a title in one submenu go in either
order), the binding it replaced and the submenus it had to create. A command that is no longer the registered one
(undefined, or defined again) has its item taken out, newest first: a replaced item is put back in its place, a submenu
made for the item goes once empty, and an item someone else replaced or removed since is left alone. Every other
item is replaced where it stands (`easy-menu-add-item` keeps the position, and refreshes `:keys`), so nothing untouched
moves behind an item someone else added meanwhile. `drgnx-surfaces-apply-which-key` already removes its previous labels
on every refresh. Right-click contexts: `(drgnx-surfaces-undefine-context CONTEXT)` removes one;
`drgnx-surfaces-define-context` called from a setup claims the context (the same claims as the option and key helpers),
so two modules defining one context, and a user's own definition on top, undo in any order.

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

**modules.eld** is a config file (`drgnx-config-define 'modules`, format 2, read at start, last good copy kept; the
reference is `docs/reference/config.md`). `(drgnx-modules-read-state)` is `(drgnx-config-get 'modules)`: what this Emacs
applied at its start, or after its own write. Every writer goes through `(drgnx-modules-update-state FN)`
(`drgnx-config-update`): FN gets the file as it is now, under the file's lock, so a change another Emacs (batch
onboarding, a second daemon) just made is kept, and only the keys FN changed are written. `drgnx-modules-toggle`,
`drgnx-modules-set-enabled`, `drgnx-modal--set-enabled`, `drgnx-onboard-apply-preset` and the theme write
(`drgnx-look-load-theme`, onboarding) use it; a flow with a side effect before its write calls
`(drgnx-config-ensure-writable 'modules)` first. A modules.eld with a mistake or one a newer drgnx wrote is never
written (`drgnx-config-refused`); an older one (format 0, a bare list; format 1) is migrated in memory and written as
format 2 by the first write, after a backup. A malformed `:external` entry is not a file mistake: that module is
reported failed (`drgnx-modules--external-ok-p`). The Modules list reads the "Next start" column from the file, fresh.

### Teardown: the cleanup stack (`drgnx-modules-record.el`)

A module can be turned off while Emacs runs. While its setup runs, `drgnx-modules--current` names it, and each call
that changes global state pushes its own undo onto the module's cleanup stack (the shape of buttercup's cleanup
stack — the code that knows what it changed knows how to change it back):

```elisp
(add-hook 'find-file-hook #'drgnx-blame--maybe)
(drgnx-modules-push-undo "hook find-file-hook drgnx-blame--maybe"
                         (lambda () (remove-hook 'find-file-hook #'drgnx-blame--maybe)))
```

- `(drgnx-modules-push-undo LABEL UNDO)` records only during a setup, and only the setup's own code: the top level
  of a library the setup loads registers for itself and stays (`require` cannot be undone; the code stays loaded
  until restart). "Own code" means the `load-file-name` the setup began with — the startup stage itself runs
  inside a `load` (`init.el` calls `drgnx-init`), so "a load is in progress" cannot tell the two apart; a nested
  `load` or `require` binds `load-file-name` anew (`drgnx-modules--recording-p`). Outside a setup it costs one
  variable test. LABEL is a short description for reports; UNDO, a function of no arguments, first checks that the
  state is still what this module set and changes nothing otherwise — it never removes what someone else added
  since.
- Whatever runs synchronously inside a setup pushes onto the module whose setup runs — including another owner's
  hook functions it runs (a nested stage's `drgnx-modules-after-stage-functions`) — and a module whose setup is run
  from another's records onto its own stack. Code a setup defers (`eval-after-load`, a timer) runs outside it
  and records nothing unless it names its owner (`drgnx-modules-with-owner`, below). That holds also when the
  deferred code runs *inside* a setup: `eval-after-load` forms that a setup's `require` triggers belong to nobody
  (see the safety net).
- `:teardown` in `drgnx-module-define`: a function for what the stack cannot see (a theme, live frames' parameters,
  a mode turned on in live buffers, a sub-module's own state), or `restart`: the module is not turned off while Emacs
  runs, only at the next start. Anything else is an error when the module is defined, so the function must be
  defined before the `drgnx-module-define` form.
- `(drgnx-module-teardown NAME)` runs the module's `:teardown`, then its stack last in first out inside
  `unwind-protect`, each undo under its own error guard, and forgets the stack; the status becomes `off`. It returns
  the problems (nil when clean) — a failed undo is named by its label, a failed `:teardown` by `teardown` — and never
  raises. A module that is not running does nothing, and so does a `:teardown` that tears its own module down
  again. A `restart` module (and an external one) stays running and returns `("restart")`. After a batch of
  teardowns the caller runs `drgnx-modules-after-teardown-functions` once.
- A setup that does not finish — an error, a quit, a throw — is rolled back: the undos it pushed run, newest first.
  After an error the module is `failed`, with the error and any undo problems in the report; a quit or a throw goes
  on after the rollback.
- Running a module that is already on tears it down first (its `:teardown`, then its stack), so no undo is left
  behind; a `restart` module is set up again on top, as before, and keeps its earlier undos. That teardown does not
  run `drgnx-modules-after-teardown-functions`: the setup registers its commands again at once, and `drgnx-modules-run`
  runs `drgnx-modules-after-stage-functions` (keys and menus apply) once after the whole stage, so a hook per re-run
  would only add a second full keys resolve while the registry is half rebuilt. Whoever tears down on purpose
  (Preferences, the batch teardown) runs the after-teardown hook once.
- Preferences: Modules calls `(drgnx-modules-turn-off MODULE &key dependents)` and `(drgnx-modules-turn-on MODULE)`
  (`core/drgnx-modules.el`; user guide: `docs/guide/modules.md`). Turn-off returns the running modules that
  `:requires` MODULE, doing nothing, unless `:dependents t`: then it tears them down deepest first, then MODULE, runs
  the after-teardown hook once and writes MODULE with `drgnx-modules-set-enabled`. If MODULE is `restart`, or a
  running dependent is, it only writes (nothing torn down; the dependents wait for it at the next start). Turn-on
  writes it and, when the report shows the module's stage has run, calls `drgnx-modules--run-one` (which checks
  packages and requirements) and runs `drgnx-modules-after-teardown-functions` (not the after-stage hook, whose
  subscriber skips `startup`) so keys and menus follow whatever the stage. Neither prompts; the question "Also turn off X, Y?" belongs to the
  command `drgnx-modules-list-toggle`. `drgnx-modules-toggle` (onboarding) only writes.
- Teardown and rollback run in automatic paths: they never prompt. Undos and `:teardown` run with
  `inhibit-interaction` bound, so one that would ask fails at once and is reported. Every undo checks before it
  changes anything, so off, on, off is the same as off once, and two undos of the same thing (a `:teardown` that
  calls a sub-module's off function, then the stack) leave it undone once.

#### Workbench registries (`wb/`)

The workbench's registries push their own undo, so a module that defines a section, a tab, a rule, a place or a
bus subscription in its setup leaves none behind. Each undo changes the entry only while it is still the one this
module defined; a definition that replaced an entry puts the previous one back instead of removing it. Each
definition claims its target with the helpers' claims (`drgnx-module--claim`, `drgnx-module--release`: a section by
name, a tab by area and name, a rule by matcher, a place by name), so two modules that define the same one end where
they started whichever is torn down first.

| Define | Undo (also callable on its own) | Open panes |
|---|---|---|
| `drgnx-wb-define-section` | `(drgnx-wb-undefine-section NAME)` | the section's dock window closes (focus leaves it first); the dock keeps its other sections. A restored previous section shows again the next time the dock is shown. |
| `drgnx-wb-define-tab` | `(drgnx-wb-undefine-tab AREA TAB)` | where the area shows the tab it shows the next tab in the same window (the one before for the last tab), or hides when it was the only one; the tab row is redrawn and the frame's saved buffer for the tab dropped. A restored tab replaces the module's placeholder in a window that shows it. |
| `drgnx-wb-place` | `(drgnx-wb-unplace MATCHER)` (`equal`) | none: rules decide only where a buffer goes next. |
| `drgnx-wb-define-place` | `(drgnx-wb-undefine-place PLACE)` | none. A rule that still names an undefined place sends its buffers to the editor, with a one-time message. |
| `drgnx-signal-subscribe` | `drgnx-signal-unsubscribe` | none. A count per (event, function): each module's subscription holds it and the last release unsubscribes. A function already subscribed by code that records nothing (a mode, the user) is never unsubscribed by a module. A subscription re-made outside a setup (a mode switched off and on by the user) while a module holds one is unsubscribed with the module's last release. |

The `add-function` on `after-focus-change-function` (Explorer and Buffers panel) pushes its `remove-function`
beside it, by the advice's name. Areas (`drgnx-wb-define-area`) are not undone: they belong to the workbench.

#### Helpers that undo themselves (`drgnx-modules-helpers.el`)

Four changes a setup makes to global state are done through a helper that makes the change and pushes its own
undo. Each undo runs only while the state is still what this call set, so it never removes what the user, a theme
or another module put there since. Outside a setup a helper only makes the change.

| Use | For | Undo |
|---|---|---|
| `(drgnx-module-set VAR VALUE)` | another package's option, instead of `setq`, `setopt` or `setq-default` | puts the old value back (VAR unbound again if it was) |
| `(drgnx-module-alist-put VAR KEY VALUE)` | one key of an alist such as `auto-mode-alist`, `major-mode-remap-alist` or `default-frame-alist`, instead of `setf alist-get` | puts the old entry back, or removes KEY when there was none |
| `(drgnx-module-face-spec FACE SPEC)` | a face's default spec, instead of `face-spec-set` | puts the previous default spec back |
| `(drgnx-module-define-key MAP-SYMBOL KEY DEF)` | a remap or a mouse/chrome event in a global map such as `global-map` | puts the previous binding back, or removes the entry |

- `drgnx-module-set` sets through the option's custom `:set` function when it has one, else `set-default`, and the
  undo goes through the same setter, so a `:set` that does more than store runs again on the way back. The undo runs
  while the default value is still the one stored (what a setter stored, which can differ from VALUE).
- `drgnx-module-alist-put` compares keys with `equal` (an `auto-mode-alist` key is a string) and replaces the alist
  instead of changing it, so a list shared with the original value is never mutated. It stores through the
  variable's custom `:set` function too, and an alist that is not loaded yet counts as empty. A hook or an advice
  has its own helper.
- `drgnx-module-face-spec` touches only the face's default spec (`face-defface-spec`); what the user customized or a
  theme set lives apart from it and is never touched. `face-spec-set` recalculates the face, so an attribute set
  directly with `set-face-attribute` is wiped by it (at the set and again at the undo): give such a face its look
  through the spec.
- `drgnx-module-define-key` binds in the keymap object, never rebinding the variable, and looks at the map's own
  entry (not its parent's). A keyboard key signals an error: typed keys come from the key profiles
  (`keys/*.eld`). Allowed: `[remap CMD]`, the chrome (`menu-bar`, `tool-bar`, `tab-bar`, `tab-line`,
  `header-line`, `mode-line`, scroll bars, fringes) and any key whose last event is a mouse or wheel event.
- **Two modules, one target.** Each helper claims its target (the option, the alist key, the face, the key in the
  map) and remembers what it found there. Tearing the modules down in any order ends where they started: an undo
  that is not the newest claim leaves the live value alone and hands what it found to the claim above it; the
  newest one restores, if the value is still what it set (so a change by the user stays). A claim is dropped only
  by its undo, so a module that is never torn down (a `restart` module) keeps its claim until restart.
- The undo compares with `equal`: a list stored by reference and changed in place later still equals itself, so the
  undo overwrites that change. Do not mutate a value you gave `drgnx-module-set`.
- Outside a setup the helpers make the change and nothing else (no label, closure or claim).

#### Hooks and advice: `drgnx-module-hook` and `drgnx-module-advice`

A global hook function or advice a module adds goes through a paired helper (Doom's `add-hook!` and `defadvice!`
shape). It defines the function with a name and an owner, adds it, and pushes its removal, which is what
AGENTS.md asks of every global hook and advice ("named, with an owner", no lambdas).

```elisp
(drgnx-module-hook 'find-file-hook maybe ()           ; defines drgnx-editor/blame--maybe
  (drgnx-blame--check))
(drgnx-module-hook '(text-mode-hook prog-mode-hook) enable () :depth 90 (drgnx-blame-mode 1))
(drgnx-module-advice 'save-buffer :after refresh (&rest _) (drgnx-blame--refresh))
(drgnx-module-unhook 'find-file-hook maybe)           ; early, e.g. when a mode turns off
```

- The function is `drgnx-<module>--<NAME>`, the module being the one the file's `drgnx-module-define` names (the
  file's forms are read at macro-expansion time, so comments and strings never count; cached by the file's mtime) or
  `:module NAME` (a symbol) first in the body. NAME is a plain symbol and is used once per module file: the same
  NAME for two helpers is an error at expansion. `:depth N` goes to `add-hook` (`drgnx-module-advice` refuses it).
  HOOK is evaluated: a symbol or a list of symbols; SYMBOL and HOW of an advice are evaluated. The advice is named
  by its function (`advice-add` name property), so equal NAMEs in two modules never replace each other.
- Running a helper again changes nothing. The undo takes the function off only when no claim on it is left: the
  helpers use the claims of the section above (target: the hook and the function, or the advised symbol and the
  function), so two modules adding the same named function tear down in either order, and a function that was on
  the hook before the module added it stays. `drgnx-module-unhook` and `drgnx-module-unadvise` drop the calling
  module's own claim early (its teardown then has nothing left to do); another module's claim keeps the function in
  place. Outside a setup the helper adds and records nothing; a name is a symbol, never a lambda.
- The safety net of the cleanup stack (below) records raw `add-hook` and `advice-add` calls a setup makes. It
  skips the helpers' own changes: every claim-aware helper (these two, and `drgnx-module-set`,
  `-alist-put`, `-face-spec`) makes its change inside `drgnx-modules--quietly`. A raw call is a fallback; use the
  helper.

#### Subscribe, don't hook

A module does not add its own function to `window-buffer-change-functions`, `window-size-change-functions`,
`window-state-change-functions` or `window-configuration-change-hook` (globally or buffer-locally), and does not call
`get-buffer-window` with a second argument to find out whether a buffer shows. The workbench state store watches the
windows once and tells subscribers what changed; a module subscribes to the events it needs. The lint
`drgnx-lint/modules-subscribe-instead-of-window-hooks` (`test/unit/lint-state-test.el`) reads every file under
`modules/` and fails on such a site that `test/lint-state-allowed.eld` does not name. Each entry there is
`(:file F :what W :why STRING :until TASK)`: the sites that exist today, each with the task that moves it. The task
that moves a site deletes its line, because `drgnx-lint/no-stale-allowlist-entries` fails on an entry that matches
nothing. A new site is not added to the list; it subscribes instead.

The Live view is such a consumer (`drgnx-live--subscribe`, from the module's setup): `drgnx-live--shown-again` on
`windows-changed` and `drgnx-live--resized` on `pane-resized`, both on the `idle` lane. Each takes the windows of the
event's frame that show a Live view (not only the window the event names: an idle subscriber gets one event per
frame and kind, the last, so a divider moved between two editor windows names only one of them), remembers the window
in `drgnx-live--seen-window`, and acts: resume the screencast, or restart it at the window's width.
`drgnx-live--window` returns the remembered window while it is live and still shows the view, else the first window
of `drgnx-state-windows` that does.
### A run's end

A module's setup run has a token (`drgnx-modules--runs`). It ends when the module is turned off, when its setup is
rolled back, and when its setup runs again while the token is still there (a `:teardown 'restart` module run again).
`drgnx-modules--end-run MODULE` drops the token and then calls each function of `drgnx-modules-run-end-functions`
with MODULE, under `condition-case` and with `inhibit-interaction` t; a failure becomes a problem
`"run end: FN: MESSAGE"` in the teardown's, the rollback's or the new run's problems, and the next function still
runs. `drgnx-timer.el` adds `drgnx-timer-cancel-owner` at load: **a module's layer timers die before its `:teardown`
runs**, whether the setup, deferred work (`drgnx-modules-with-owner`) or a later hook with `:owner` started them,
and their keys leave the table. A timer owned by a buffer or a process is not the module's and stays.

### The safety net: what a setup reaches through Emacs's own doors

Code a setup reaches that does not push its own undo — wb modes, the setup functions of `wb/` libraries, packages'
mode functions — is recorded anyway. For each setup's extent only (`drgnx-modules--with-recorder`, inside
`drgnx-modules--run-setup`), drgnx advises five functions and removes the advice in `unwind-protect`, also after
an error, a quit or a throw (a second quit during the removal is held off). Outside a setup nothing is advised and
no call goes through the net; what stays is two properties `advice-remove` leaves on each advised symbol's plist
(`function-documentation`, `defalias-fset-function`), which change nothing.

| What the setup does | Recorded when | Undo (each checks first) |
|---|---|---|
| `add-hook` on a hook's global value | the function was not on it before | `remove-hook`, if it is still there |
| `advice-add` | `advice-member-p` was nil before | `advice-remove`, if still there |
| `add-to-list` on a list's global value | the element was not a member before (same test as `add-to-list`) | remove that one element, if still a member; others' additions stay |
| `eval-after-load` (also what `with-eval-after-load` expands to) | the function it adds was not in the feature's `after-load-alist` entry before | removed from the entry, if still there; others' forms stay. Emacs adds the function even when the feature is already loaded and keeps it after the feature loads: left there, a module turned off would keep an entry, and turned on again its new function would be dropped as `equal` to the old one, so its deferred work would never run |
| a new timer (`timer-list`, `timer-idle-list` compared before and after) | its function is a symbol defined under `drgnx-dir` (a layer timer is skipped: its run token owns it; anything else is *left*, below) | `cancel-timer`, if still pending |
| a global minor mode newly in `global-minor-modes` | it was off before | `(MODE -1)`, if still on; pushed after everything the setup pushed, so modes go off first and their own off code runs before the hook and timer undos. This is the one break in last in, first out: a mode goes off before undos the setup pushed after turning it on |
| a feature newly in `features` | always | none: kept for the report, `(drgnx-modules-features-of MODULE)` |

Labels read `hook HOOK FN`, `advice SYMBOL FN`, `list VAR ELEMENT`, `after-load FEATURE`, `timer FN`, `mode MODE`, cut to 100 characters. The undos make teardown and rollback complete for these doors.

The net's undos are unconditional: they check that the thing is still there, not whether another module still
needs it. So a change made by a claim-aware API — one whose undo hands over to another module's claim (the helpers
above) — must not also be recorded by the net: such an API makes its change inside `drgnx-modules--quietly`, which
binds `drgnx-module--in-helper` (the three advices record nothing) and marks the timers and global modes started
in its extent as seen, for nobody. Then a mode that module A's option turned on stays on while module B's claim on
the option stands. A plain `drgnx-modules-push-undo` next to a raw call (an unconditional undo too) may be
recorded twice; that is harmless, since the second finds nothing to do.

What it does **not** record:

- **Buffer-local changes**: `add-hook … nil t`, a buffer-local list value. Buffers own those.
- **`add-to-list` on `global-minor-modes` or `local-minor-modes`**: Emacs 31's `define-minor-mode` keeps them that
  way; the modes are compared after the setup instead.
- **A drgnx helper's own changes** (`drgnx-modules--quietly`, above).
- **Timers drgnx did not make are left, and listed.** The net cancels a timer only when its function is a symbol
  defined under `drgnx-dir`. Anything else — Emacs, an ELPA package, a user's module outside `drgnx-dir`, a lambda —
  may be a library's singleton, started lazily from code a setup calls (an edit starts undo's boundary timer, a buffer's
  jit-lock its context timer) and kept in a variable; cancelled, it would stay dead for the session (undo boundaries
  for process output would stop). Such a timer stays pending, and the module's report says so: `:left`, a list of
  `"timer FN (FILE)"` (FILE is where FN is defined, `no file` when it is not) or `"timer a lambda"`, newest first. It
  is cleared when the module's run starts and is in `modules-report.eld`. Read it as "this module's setup started
  these, and turning it off did not stop them": a line for a function that is the module's own means the module should
  start it through `drgnx-timer-start`, which ends it with the run.
- **Global modes are owned by the first module that turns them on.** "Newly on" is all the net sees: when module
  A turns `drgnx-signal-mode` on and B relies on it, tearing A down turns it off. Modes a module shares go through
  an option (`drgnx-module-set`, claim-aware) or B's `:teardown`/`requires`. And a mode a setup turns *off* is not
  turned back on at teardown.
- **Timer callbacks that fire inside a setup** (`sit-for`, `accept-process-output`) run with the module current,
  so what they change is recorded onto it.
- **The top level of a library the setup loads** (hooks, advice, list entries): it registers for itself and stays
  (`drgnx-modules--recording-p`). Timers and global modes are found by comparing lists, so one that a library
  starts at its top level while the setup loads it *is* recorded onto the setup — a library that does that is
  itself the bug.
- **`eval-after-load` forms that the setup's `require` triggers.** They run once, when their library loads, after
  `load-file-name` is back to the setup's. Recorded, turning the module off would undo them and turning it on
  again would not bring them back (the library is already loaded). So while they run (`do-after-load-evaluation`
  is advised too) no module is current, and the timers and modes they start are claimed by nobody. A form that
  names its owner records onto it.
- **A setup run inside another's** records onto its own module only: what an inner recorder found is claimed,
  and the outer one skips it.
- **`add-to-list` that the compiler rewrote.** Its compiler macro turns `(add-to-list 'VAR …)` into a plain
  `push` when VAR is not special at compile time — a lexical variable, or one whose `defvar` the compiling Emacs
  has not run, such as one defined in the caller's own file or declared with a bare `(defvar VAR)`
  (`drgnx-search.el`'s `drgnx-ai-retrievers`). Checked on 30.2 and 31.1. Use `drgnx-modules-push-undo` (or the
  module helpers) for such a list.
- `setq`, `setf`, `put`, `add-function`, key bindings, faces, frames: the module's own undo or `:teardown`.

**Deferred work: `drgnx-modules-with-owner`.** `(drgnx-modules-with-owner BODY…)` evaluates to a function: it
names the module whose setup evaluates the form, and when called later runs BODY as that module's code, with the
safety net — what BODY changes is recorded onto the module, as in its setup. Use it as the deferred thing itself:

```elisp
(eval-after-load 'drgnx-ai-ui (drgnx-modules-with-owner (add-to-list 'drgnx-ai-retrievers #'my-retriever t)))
```

A timer needs no wrapper: `(drgnx-timer-start 'my-key 1 #'my-fn :idle t)` in a setup is owned by that module run by
default, and its one-shot runs as the module's code, recorded the same way ([Timers](#timers), below).

Not `(with-eval-after-load 'x (drgnx-modules-with-owner …))`: there the form is evaluated only when `x` loads, so
it names no module, and its function is never called. Once the module is turned off, rolled back, or run again
(each run of a setup gets a fresh token in `drgnx-modules--runs`), the function does nothing and returns nil, so a
late `eval-after-load` or idle step of a turned-off module never runs and an off-on cycle never runs the old run's
work twice. Evaluated outside a setup, it just runs BODY. Each call installs the safety net for its extent (about
20 µs): for one-off work, not for a hook that runs on every command.

**Cost.** The safety net around a setup costs 16–22 µs (byte-compiled, 30.2, measured with four doors: four `advice-add` and
`advice-remove`, two snapshots and their comparison), and up to about 70 µs in runs where the garbage it makes
brings a collection forward (65–73 µs measured so); 41 setups × 75 µs ≈ 3 ms at worst. The shipped startup stage (16 modules, batch) took 29.4 ms with
it and 28.2 ms without (5 runs each, within the runs' noise); the budget is 5 ms across all setups. The fifth door
(`eval-after-load`) adds one `advice-add` and `advice-remove` pair per setup, a few µs, not measured on its own.
`test/unit/modules-record-test.el` covers it, including `startup-is-unchanged`: the shipped modules' startup stage
gives the same statuses and commands with the recorder as without it.

### Writing a module that can be turned off

**Every module can be turned off.** A module's `:setup` changes global state only through recorded doors: drgnx's
`define` functions, `drgnx-module-hook` / `drgnx-module-advice` (named, paired with their removal) or `add-hook` /
`advice-add` of a named function, timers, `add-to-list` of a `defvar`ed variable (see "`add-to-list` that the
compiler rewrote" above), `eval-after-load`, global minor modes, `drgnx-module-set` for another
package's options, `drgnx-module-alist-put` for alist keys, `drgnx-module-face-spec` for face specs and
`drgnx-module-define-key` for remaps in global maps. Anything else — a theme, a connection, live frames'
parameters, a mode turned on in live buffers, a sub-module's own state — is undone by the module's `:teardown`
(which calls the sub-modules' off functions), or the module declares `:teardown 'restart`. A test never stubs a
setup to keep its effects out of the process: it sets the module up and tears it down. Code a setup defers
(`eval-after-load`, a timer callback) runs inside `drgnx-modules-with-owner`. Files under `modules/` register
nothing at top level. A new registry calls `drgnx-modules-push-undo` and has an undefine. Tests that set modules up
use `drgnx-test-with-modules` ([harness.md](harness.md)), and `bin/drgnx test --leaks` reports nothing for the
tests you add.

`test/unit/lint-teardown-test.el` checks it:

- `drgnx-teardown/every-module-leaves-nothing` sets each shipped module up alone with
  `(drgnx-test-with-modules (list M) :strict t)` and turns it off: the state after equals the state before, taken
  after the libraries its setup loads are loaded (features excepted, and the timers the recorder leaves alone;
  [harness.md](harness.md)). Every module is checked and the failures are reported together, each named with its
  module and what it left. Packages come from the
  user's ELPA when present (read-only, `DRGNX_USER_ELPA`), and no outside program is found, so none starts; a module
  whose packages are missing does not set up, and the test's message says which were not set up.
  `drgnx-teardown/off-on-off-is-off` turns each one off and on again in between: the second setup must set up the
  same things as the first, compared by what they are (a timer made again is a new object but the same timer) —
  no stacked timers, no idempotence guard that outlived the teardown.
  `restart` modules are not set up here: their own tests set them up `:strict`, and the helper unwinds their record
  (`core/basics`, `core/workbench`: `test/unit/mod-core-test.el`).
- `drgnx-lint/modules-register-nothing-at-load`: a registration (`add-hook`, `advice-add`, `add-to-list`,
  `with-eval-after-load`, a timer, a drgnx `define`…) that runs when a module file loads fails — it runs outside every setup, so nothing records it.
- `drgnx-lint/raw-global-forms-need-a-teardown`: in a module file, `with-eval-after-load` or an `eval-after-load`
  without `drgnx-modules-with-owner`, `setf (alist-get … VAR)` on a global variable, `face-spec-set`,
  `custom-set-*`, `setopt`, `setq-default`, `define-key global-map`, `default-frame-alist`,
  `modify-frame-parameters` and `add-function` on a global variable fail unless the module has a `:teardown`. Two fail whatever it has: a lambda on a global
  hook (name it) and `drgnx-modules-with-owner` directly inside `with-eval-after-load` (evaluated only when the
  feature loads, it names no module and never runs).

Modules not converted yet are on `drgnx-teardown--not-yet`, each with the migration batch that converts it; the
dynamic check and the raw-forms lint skip them, and the test's message counts them. Known top-level registrations
waiting for their batch are on `drgnx-teardown--load-registrations`; an entry whose registration is gone fails
too. Both lists shrink to empty. A file under `modules/` that defines no module is listed in
`drgnx-teardown--library-files` with the module that uses it.

## Timers

### Keys and owners (`drgnx-timer.el`)

A timer that outlives the current command goes through one door:

```elisp
(drgnx-timer-start KEY SECS FN &key repeat idle args owner)   ; → KEY, or nil when OWNER is gone already
(drgnx-timer-start 'my-key 1 #'my-fn :idle t)                 ; in a setup: owned by that module run
(drgnx-timer-start (cons 'my-check buf) 30 #'my-check :repeat 30 :owner buf)
```

FN (with ARGS) runs after SECS, or after SECS of idleness with `:idle t`. `:repeat` is a number of seconds for a wall
timer and non-nil for an idle one (once per pause), as in `run-at-time` and `run-with-idle-timer`; a wall timer's
`:repeat t` signals `wrong-type-argument` on every Emacs (Emacs 31's `run-at-time` refuses it, Emacs 30 ran the timer
once). Then
`(drgnx-timer-cancel KEY)`, `(drgnx-timer-active-p KEY)` and `(drgnx-timer-cancel-owner OWNER)` (→ how many).

- **The key.** A second start of a KEY cancels its pending timer first, whatever started it: a setup run twice keeps
  one timer. KEY is a symbol named after its site (`hub-tick`, `persist-visit`), or `(SYMBOL . OBJECT)` for one timer
  per buffer, process or root, OBJECT a symbol, number, string, buffer, process, frame or window. Keys are compared
  with `equal`, so a struct or a list would hash by contents that change (a connection struct whose stderr grows):
  anything else signals `wrong-type-argument`. Key a timer by the process, never by its connection struct.
- **The function** is a symbol (`list-timers`, the fingerprint and the errors name it); a lambda, a closure or an
  `apply-partially` signals `wrong-type-argument`.
- **The owner.** nil (the default) is the module whose setup or `drgnx-modules-with-owner` code runs now, with its
  run token, else `:core`. A module symbol (`:owner 'tools/agents-ui`, from a hook function that runs later) takes
  the module's current run; a module with no run refuses the start (nil, nothing started). A buffer owns its timers
  until it is killed: its first timer adds `drgnx-timer--buffer-killed` to the buffer's own `kill-buffer-hook`
  (permanent-local, as is its key list `drgnx-timer--buffer-keys`; no global hook). A process owns them while it
  lives; its sentinel (or the job runner) must call `(drgnx-timer-cancel-owner PROCESS)` when it dies, which also
  forgets the last runs of its `:min-interval` keys. `:core` lives as long as Emacs (the hub tick, the idle GC under
  the key `gc-idle`, the job stamp poll `(jobs-stamp . ID)`, the usage write `surfaces-usage`).
  Module repeats are keyed this way: `tools/agents` owns `agents-ui-mirror` (idle, every 30 s; its first look is the
  one-shot `agents-ui-mirror-first`, 3 s into the first pause) and `tools/jobs` owns
  `job-ui-recount-idle` (idle, every 60 s), so a second setup replaces the timer instead of stacking another, and
  turning the module off ends it. Timers started later (from a command or a hook) name their module with `:owner`:
  `tools/agents` owns the Agents list's 30 s tick `agents-ui-tick` (it only marks the list's view, and runs only while a window shows the list; see Views),
  `ui/face` owns quick help's `quickhelp-timeout`, `-unmap`, `-look`, `-away` and `-hover` and the start page's
  `start-first-frame`, `ui/terminal-popups` the debounced `tty-popups-show`, `ui/terminal` the per-frame
  `(tty-fallback-hint . FRAME)`, `tools/jobs` the coalesced `job-ui-recount`, `tools/ai` the `ai-probe` one-shot; the
  ghost-text pause is an idle debounce `(ai-ghost . BUFFER)` owned by the buffer, the Search view's typing pause
  and its pause after a listed file changed are debounces `(replace-pause . BUFFER)` and `(replace-refresh . BUFFER)`
  owned by the view's buffer (its rows are a view: below); a search's output is parsed `drgnx-replace-parse-lines`
  (64) lines at a time, the rest by `drgnx-timer-soon` `(replace-parse . PROCESS)` owned by the search's stderr
  buffer (killed when the search ends; `drgnx-replace-cancel` also cancels the key, since that buffer runs no
  kill hook). A line that does not parse is left out, and the first such error reaches the callback as `(:error
  REASON)`; a partial line's pieces are joined once, at its newline. And an Ask's search limit
  `(ai-grep . PROCESS)` by the search process (its sentinel cancels it). With no run of the owner nothing starts.
  Core process timeouts are keyed by their process and owned by it, so the layer drops them when it dies: a check's
  limit `(agent-check-limit . PROC)` with its 3 s backstop and tree kill, the hung `systemctl` kill, a `claude` command's
  limit `(claude-cli-limit . PROC)` and the gateway's `(gateway-close . CONN)`. Three core timers have no process to own
  them and belong to `:core`: `ai-load-keys` (once per daemon, after `drgnx open`), `ai-first-window` (the idle look at
  the local AI runner) and a finished check's 0.1 s `(agent-check-finish . PROC)`, whose process is already dead. The status bar's debounced refresh is a fourth, `statusbar-refresh`, cancelled when the bar's mode turns off."

The Work cockpit's panes start their checks on the workbench state store's `pane-shown` and cancel them on
`pane-hidden` (lane `now`), so a hidden pane keeps no timer: the Work graph's `(cockpit-check . BUFFER)`, owned by its
buffer, every `drgnx-cockpit-check-interval` (it also hears `windows-changed`, lane `idle`, since it can show in any
window); an agent's edits pane's `(cockpit-edits-check . BUFFER)` (with its one-shots `-tick`, `-turn` and `-flush`,
and its file watches, all dropped when it is hidden; it also hears `windows-changed`, lane `idle`, since its buffers
swap in one window); a feed buffer's `(cockpit-feed-check . BUFFER)` (also on
`windows-changed`). What needs you and the decision log share `cockpit-cards-refresh` and `cockpit-cards-retry`
(`:core`), cancelled when neither shows. Their draws are their views' timers. `tools/cockpit` owns `cockpit-waiting`
(its setup's: the status bar's count of what waits on you, every `drgnx-cockpit-check-interval`); its `:teardown`
kills the cockpit's buffers, so turning it off leaves no timer.

`core/drgnx-platform.el` (window-manager calls) owns its timers as `:core`: each belongs to one call that ends itself
(its answer, its error) and cancels the timer, so no module's end or process's death may drop one and leave the
callback uncalled. They are keyed per call: `(platform-call . PROCESS)` (the tool's time limit),
`(platform-watchdog . N)` (an adapter that never answers), `(wm-place-poll . N)` and `(wm-place-deadline . N)` (sway
and i3 placement), `(wm-hn-poll . N)` (Hyprland and niri placement), `(kwin-answer . N)` and `(kwin-place . N)`.

### What the fire wrapper guarantees

Every layer timer's Emacs function is `drgnx-timer--fire` with the entry as its argument. At each firing, in order:

1. A timer whose key now holds another entry (replaced or cancelled while it was ripe) does nothing.
2. An owner that is gone (a module turned off, rolled back or run again; a dead buffer or process) drops the entry:
   FN is never called for it. A buffer made with `inhibit-buffer-hooks` runs no `kill-buffer-hook`, so its timers
   go here, at their next firing.
3. A one-shot leaves the table before FN runs, so FN may start its key again.
4. FN runs in `save-match-data`, with a buffer owner current. A one-shot `drgnx-timer-start` owned by a module runs
   as the module's code (`drgnx-modules--record-call`, as `drgnx-modules-with-owner` work does): what it changes is
   undone when the module is turned off. A repeating timer and every firing of the primitives (debounce, soon,
   poll, idle steps, their ON-TIMEOUT and ON-DONE) do not install the safety net, so they must not register hooks,
   advice or global modes.
5. Every error is caught: pushed on `drgnx-timer-errors` (newest first, at most 50 plists
   `(:key :owner :fn :error :failures :stopped :time)`) and shown once as `drgnx: timer KEY failed: MESSAGE`. A
   success resets the count. A timer that would run again (repeating, a poll, idle steps) stops at its
   `drgnx-timer-failure-limit`-th failure in a row (3): it is cancelled, its record says `:stopped t`, and
   `timers-report.eld` in the state dir (`drgnx-timer-report-file`; the hub writes `hub-timers-report.eld`) is
   rewritten, buffers and processes in it written as their printed names. The doctor's `timers` check lists what
   stopped in the last session. The debugger opens only with `debug-on-error` and a frame to show it: never in batch
   or a daemon with no client. Nothing on these paths prompts.

`(drgnx-timer-describe TIMER)` → `(:key K :owner O :kind KIND :fn FN)` for a layer timer (O without the run token),
else nil; `(drgnx-timer-pending)` → `(KEY OWNER KIND)` for every live key; `(drgnx-timer-reset)` cancels them all
(tests and the census). The layer never cancels a timer it did not make.

### The primitives: debounce, soon, poll, idle steps

Four calls cover the idioms a hand-written timer used to. Each takes a KEY, an `:owner` (default as in
`drgnx-timer-start`) and a named function, returns KEY (nil when the owner is gone already), and fires through
`drgnx-timer--fire`, so the owner check, the error record and the failure limit are the same.

```elisp
(drgnx-timer-debounce KEY SECS FN &key args idle owner)
(drgnx-timer-soon KEY SECS FN &key args idle min-interval owner)
(drgnx-timer-poll KEY INTERVAL FN &key deadline on-timeout args owner)
(drgnx-timer-idle-steps KEY SECS STEP &key args budget interruptible owner on-done)
```

| The old idiom | Use |
|---|---|
| cancel the timer and start it again on every event | `drgnx-timer-debounce` |
| `(unless (timerp X) (setq X (run-at-time …)))` | `drgnx-timer-soon` |
| a minimum interval between runs | `drgnx-timer-soon … :min-interval` |
| a lambda that looks "every N s" until something is true | `drgnx-timer-poll … :deadline` |
| "keep going while idle", a step at a time | `drgnx-timer-idle-steps` |
| `run-at-time 0 nil` out of a process filter or sentinel | stays raw |

- **Debounce.** FN runs with the last call's ARGS once SECS pass with no further call. While one is pending a call
  only stores ARGS and, for a wall debounce, the time (`drgnx-timer--now`): it makes no timer, does not look at the
  owner again and, for `:idle t`, reads no clock (an idle debounce arms one idle timer once; input resets idleness,
  so calls only store ARGS). A wall timer that fires earlier than SECS after the last call waits the remainder, in a
  new timer made from a delay. SECS and IDLE are those of the call that armed it. A call on a key that holds another
  kind of timer replaces it. The pending path costs 4 conses (the `&key` list) and one float per call under
  byte-compilation, no vector cell: `drgnx-timer-prim/debounce-while-pending-makes-no-timer` and
  `…/an-idle-debounce-reads-no-clock` assert it.
- **Soon.** FN runs once, SECS after the first call of a burst, with that call's ARGS; a call while pending does
  nothing and returns KEY. With `:min-interval` the delay is `max(SECS, LAST + MIN-INTERVAL - now)`, LAST being when
  the key's previous run began; a clock that stepped back never makes the wait longer than MIN-INTERVAL. LAST is
  in `drgnx-timer--last-run` (key → `(TIME . OWNER)`), kept only for keys that have a MIN-INTERVAL;
  `drgnx-timer-cancel`, `-cancel-owner` (a module's run end and a process owner's sentinel call it), `-reset` and
  the killing of the buffer that owns the key or is its OBJECT remove it. A key `(SYMBOL . FRAME)` or
  `(SYMBOL . WINDOW)` under a `:core` owner keeps its entry until one of those. `:idle t` with `:min-interval` mixes
  a wall-clock LAST with an idle delay: use it only if that is what you want. A live view uses it as its draw throttle (one key for the mark, another, plain `drgnx-timer-start`, for the
  continuation, so the interval never delays the next slice).
- **Poll.** `:deadline` is required: a positive number of seconds from the call, or the call signals
  `(wrong-type-argument numberp DEADLINE)` at once. Every INTERVAL FN runs with ARGS; non-nil ends the poll. At the
  first firing at or past the deadline ON-TIMEOUT runs with ARGS instead (once) and the poll ends. An owner that
  goes ends it with no ON-TIMEOUT; the failure limit ends it and calls ON-TIMEOUT once.
- **Idle steps.** For work that must finish soon after the user stops but never while they type. The *pause starter*
  is a repeating idle timer at SECS; after a firing that leaves work and saw no input, the *chain*, a one-shot idle
  timer SECS further into the same pause, carries on, so a pause long enough finishes all the steps. A firing calls
  STEP at least once, and again while it returns non-nil, no input is pending and BUDGET (default
  `drgnx-timer-step-budget`, 8 ms) is not spent. STEP returning nil cancels both timers, drops the key and runs
  ON-DONE. Input pending cancels the chain and the starter resumes SECS into the next pause (a stale chain is
  cancelled when the starter fires, so it never delays it). `:interruptible t` runs each step in `while-no-input`;
  an aborted step counts as input and runs again in the next pause (leave it off for steps that are unsafe to
  abort). A step that signals ends its firing with no chain; the failure limit stops the key with no ON-DONE
  (`drgnx-timer-errors` and the doctor's `timers` check show it). Drawing never uses idle steps.

All four read the clock only through `drgnx-timer--now` and schedule by delays, so the clock fixture drives them:
`test/unit/core-timer-primitives-test.el` (`drgnx-timer-prim/`).

### The ACP watchdog and the hub's timers

The agent connection and the hub are the layer's first core users; their keys are by process or name, never by the
connection struct.

- **ACP.** `drgnx-acp-start` starts the key `(acp-watchdog . PROCESS)`, repeating every 0.5 s, whose function
  `drgnx-acp--watchdog` (CONN PROC) reports an agent that died without its sentinel being called. `drgnx-acp--exited`
  and `drgnx-acp-stop` cancel the key; two connections have two keys. A watchdog that fails stops after
  `drgnx-timer-failure-limit` failures and is named in `drgnx-timer-errors`, instead of failing every half second. The
  0.05 s tick that reads the last of a dead agent's stderr is the key `(acp-exit . PROCESS)`
  (`drgnx-acp--report-exit`, one-shot, :core): the wait for the pipe is in `with-local-quit`, and a failing on-exit
  handler is recorded in `drgnx-timer-errors` while the stderr process and input buffer are still cleaned up.
- **Agent sessions.** Stop's two deadlines are the keys `(agents-stop . SESSION-ID)` (0.9 s: an agent that did not
  answer the cancel has its turn ended anyway) and `(agents-drain . SESSION-ID)` (10 s more: the held messages go
  if the late answer never came), functions `drgnx-agents--stop-deadline` and `drgnx-agents--drain-deadline`, both
  :core. A second Stop replaces the pending deadline instead of stacking another. A session with no live agent
  connection when the deadline ends its turn becomes `exited` (the old raw timer signalled
  `wrong-type-argument drgnx-acp-conn nil`).
- **Hub.** `hub-tick` (every 2 s, repeating) keeps its own `with-demoted-errors`: its steps' transient errors (a busy
  `work.db`) never reach the failure limit. `hub-deliver` is `drgnx-timer-soon` 0.1 s: a burst of session changes
  delivers once. `(hub-flush . SESSION-ID)` is `drgnx-timer-soon` 0.05 s: one `agent` flush per session per burst.
  `hub-events` is `drgnx-timer-soon` `drgnx-hub-events-interval`: `events` go at most that often. `hub-exit` is the
  `shutdown` request's exit 0.1 s later (`drgnx-hub--exit-now` with the exit function that was set when it came); a
  hub stopped meanwhile cancels it. `drgnx-hub-stop` cancels all of them. The hub's `coord/notify` deferrals
  (`run-at-time 0`) stay raw. `drgnx-hub-main` sets `drgnx-timer-report-file` to `hub-timers-report.eld`, so a timer
  the hub stops is written beside, not over, the editor's report.

### The clock seams

The layer reads time and input only through `drgnx-timer--now` (`float-time`), `drgnx-timer--idle-time`
(`current-idle-time`) and `drgnx-timer--input-pending-p` (`input-pending-p`): plain functions, never `defsubst`, so
the clock fixture ([harness.md](harness.md#virtual-time)) overrides them and the layer follows virtual time. It
schedules by delays only (SECS is seconds from now, handed to `run-at-time` or `run-with-idle-timer` as is), never by
an absolute time computed from a clock read, which the fixture would shift twice. It reads `drgnx-timer--now` only
for differences (the debounce remainder, the throttle, the poll deadline, the step budget) and to stamp `:time` on an
error record.
`(drgnx-timer-now)` is the public clock for code outside the layer (notices, drawing). `drgnx-timer/the-clock-fixture-drives-the-seams`
checks the seams against the fixture; `test/unit/core-timer-test.el` covers the rest, all on the virtual clock.

### The rule and its lint

> A timer that outlives the current command goes through `drgnx-timer-*` with a key, an owner and a named function;
> debounce, coalesce, throttle, poll and idle work use the primitives. `run-at-time 0 nil` deferrals out of filters
> and sentinels may stay raw. A timer function that waits wraps the wait in `with-local-quit`.

`drgnx-lint/timers-go-through-the-layer` (`test/unit/lint-buffers-timers-test.el`) holds the rule in `core/` (except the layer
itself), `modules/` and `wb/`. It fails for a lambda, closure or `apply-partially` as the function of `run-at-time`, `run-with-timer`,
`run-with-idle-timer`, `timer-create`, `timer-set-function` or any `drgnx-timer-*` call, and for a raw
`run-at-time`, `run-with-timer`, `run-with-idle-timer`, `timer-set-time` or `timer-set-idle-time` unless its delay is
the literal `0` and its repeat is nil or absent (`(run-at-time 0 nil FN …)` passes, lambda or not). Sites that
predate the layer are counted per file in `drgnx-lint-timers--not-yet`; the lint compares each file's number of
violations with its count, so a new raw timer fails ("use `drgnx-timer-*`") and so does a migrated one that leaves
the count too high ("lower the count"). See [check.md](check.md#lints-on-the-source). The follow-path lint
(`drgnx-lint/no-timers-in-workbench-follow-paths`) counts a `drgnx-timer-start`, `-soon`, `-debounce` or `-poll`
form without `:idle t` as a timer start in `wb/`.

## Epochs, memos and caches (`drgnx-memo.el`)

Code that runs on redisplay or per keystroke only reads what is cached. Three tools keep the cache honest and
cheap. The library needs nothing but Emacs (the recorder is reached through `fboundp`), so batch processes load it.

| Use | When | Cost of a read |
| --- | --- | --- |
| **Epoch** | Something several results depend on changes now and then, and a hook or a variable set tells you when. | 0 allocation |
| **Memo** | One result per window, buffer, frame or (no object) per session, rebuilt only when its inputs changed. | a hit allocates 0 |
| **Cache** | Many results by key: per buffer, window, frame or process, or by string, kept within a cap. | a string hit stamps with `setcdr`, 0 |

### Epochs

`(drgnx-epoch-define NAME &key per redisplay watch doc)` declares a counter. `per` is nil (one global counter),
`buffer` (a base plus one count per buffer, weak on the buffer) or `object` (an `equal` table of counts: one fixnum per
distinct object for as long as the epoch is defined, so key it by ids; it is never weak on the key, because a collected
key would take its count back to 0 and a memo could see a value again). `(drgnx-epoch NAME
&optional OBJECT)` is a fixnum: for a per epoch the base plus the object's own count, so either bump moves it;
without OBJECT, a `buffer` epoch gives its base and an `object` epoch the total of every bump. Counters wrap at the
fixnum limit. `(drgnx-epoch-bump NAME &optional OBJECT)` returns the new value; with `:redisplay t` it also calls
`force-mode-line-update` (every window for a global, base or object bump, that buffer's for a buffer's).

`drgnx-epoch` is a macro. A quoted literal NAME that is not defined signals `No epoch NAME` when the form is
expanded, so a typo fails the build; define the epoch above its first use in the file (`drgnx-epoch-define` with a
literal name is noted at expansion), or `require` the file that does. A computed NAME is checked at run time.

`:watch VARIABLES` (or `(drgnx-epoch-watch NAME VARIABLES)`) declares the variables whose setting bumps NAME;
nothing is watched until a module activates the epoch (below). The watcher `drgnx-memo--watcher`
(`add-variable-watcher`) reacts to `set`, `makunbound` and `defvaralias`, never to a reported `let` or `unlet`.
Emacs does not report every binding as a `let`, so the watcher also skips a `set` of an atom `eq` to the value
it replaces (a cons is never skipped: an in-place edit keeps its head). What that means for a per-buffer variable
such as `tab-width`, `indent-tabs-mode` or `buffer-file-coding-system`:

- already local in the buffer: `let` and `unlet` are reported as such and ignored;
- not local in the buffer: a `let` binds the *default*, and Emacs 30 reports the binding and the unbinding as a
  `set` with no buffer. Bound to the value it already has, nothing moves. Bound to a *different* value, each of the two
  reports is a global `set`: it bumps the base and moves every buffer's epoch, twice per `let`. A consumer's watched
  list must not include a per-buffer variable that other code often rebinds to other values (Task 16 checks its list
  against this);
- a buffer-local set bumps that buffer's own count (the watcher's WHERE); a global set (`setq-default`) bumps the base.

`drgnx-memo--watched` maps each variable that is watched now to its epochs.

**What is watched is a closed list**, each entry tested. A watcher costs about 0.2 µs per set (a `setq` of an unwatched
variable 0.011 µs; an empty watcher costs 0.066 µs), so it goes on variables that change rarely. **Hot values stay plain
`eq` memo keys and are never watched**: point, `buffer-chars-modified-tick`, `default-directory`, `mode-line-process`,
keycast's keys, the window's start and width. The memo compares them for free.

### Memos

```elisp
(drgnx-memo-define window-badge :on window
  :keys ((window-point object) (buffer-chars-modified-tick) (drgnx-epoch 'git)))
(drgnx-memo window-badge (selected-window) (build-the-badge))
```

`drgnx-memo-define` (a macro, `eval-and-compile`: a declaration at the top level of a file) takes an unquoted NAME and
`:on` `window`, `buffer`, `frame` or nil (one global slot). The key forms are evaluated where `drgnx-memo` is used;
they may refer to `object`. The table is weak on the object. `(drgnx-memo NAME OBJECT BUILD)` evaluates each key form
once. When every value is `eq` to the stored one it returns the stored value and conses nothing; otherwise it runs
BUILD, writes the values into the object's vector with `aset` (made on the first miss) and returns BUILD's value.
Keys compare with `eq`: use fixnums, symbols, objects and epochs, not fresh strings, lists or floats (those never
hit). `(drgnx-memo-forget NAME &optional OBJECT)` drops one object's value, or all.

### Memo clients

What redisplay reads, built once per change (PERF-L L6):

| Memo | On | Rebuilt when | Epoch |
| --- | --- | --- | --- |
| `sticky-segment` (`drgnx-sticky.el`) | window | the window's start moves, it shows another buffer, or the epoch `sticky` of its buffer moves | `sticky` (per buffer), bumped by an edit at or above the start of a window showing the buffer |
| `job-badge` (`drgnx-job-ui.el`) | none | `drgnx-job-ui--badge` is set to another string (the count changed) | none: the badge string is the key |
| `live-header` (`drgnx-live.el`) | buffer | the epoch `live-tabs` of the view moves | `live-tabs` (per buffer), bumped where the tabs, the watched tab or driving change (`drgnx-live--tabs-changed`) |

Each module activates its memo in its `:setup` (`drgnx-memo-activate`), so turning the module off empties it. The Live
view bumps by hand rather than by `:watch`: its tests and its use do not wait for the module's setup, and the sites are
all in one file. The segment and the header are read per redisplay; a hit allocates 0 (tests: `mod-sticky-test.el`,
`job-ui-test.el`, `mod-live-test.el`).

### Caches

`(drgnx-cache-define NAME &key key cap doc)` (a declaration, at the top level): `key` `object` is a weak `eq` table; a get checks `buffer-live-p`,
`window-live-p`, `frame-live-p` or `process-live-p` and drops a dead entry. `key` `string` is an `equal` table with an
LRU; `cap` is required and positive. A get stamps the entry; a put past the cap evicts the oldest stamp (a scan of the
table, on put only). `drgnx-cache-get`, `-put`, `-remove` and `-size` take the NAME and the key; `drgnx-cache-keys NAME` lists the keys (a pass over the
table, stamping nothing: not for redisplay). **Every cache has a
cap or is weak**; the docstring or `:doc` says which event or cap bounds it.

The workbench has two string caches, both activated by `core/workbench`: `git-status` (repository root → its status
plist, 16 roots; `wb/drgnx-git.el`) and `explorer-listing` (folder → `(MTIME . CHILDREN)`, 64 folders;
`wb/drgnx-explorer.el`). A root pushed out of `git-status` while its `git status` runs is not killed: the finished
run puts the root back (`drgnx-git--done` sees no entry and no earlier read of that process). A folder the Explorer shows
is got on every render and stays recent; a tree with more than 64 expanded folders re-lists the oldest on each
render (an `mtime` check, then a directory read).

### Declarations, activation and ownership

`drgnx-epoch-define`, `drgnx-memo-define` and `drgnx-cache-define` are **declarations, like `defvar`**: they go at
the top level of a file (`core/` or `modules/`), run once at load, and are never undone. They have to be
declarations: `drgnx-epoch` and `drgnx-memo` read them when the code that uses them is expanded or compiled, and a
definition inside a `:setup` runs once at load from source but once per setup when compiled
(`eval-and-compile`). They are listed in `drgnx-memo--registry` and `drgnx-memo-census`, and the fingerprint does not
treat them as owned registrations. An epoch keeps its count across a redefinition.

What a module **owns** is what has a global effect, and it takes it in its `:setup` with one call:

```elisp
(drgnx-memo-activate 'git 'statusbar-bar 'git-status)   ; epochs, memos and caches declared above
```

For an epoch it installs the declared variable watchers (the first activation does; an epoch two modules activate
keeps them until the last is off). For a memo or a cache it records that its contents are emptied. Each step pushes
its undo (`drgnx-modules-push-undo`), so turning the module off removes its watchers and empties its memos and
caches, and turning it on again activates afresh. An epoch's count is not reset. The call does nothing recorded
outside a `:setup`, and an undeclared name signals. The fingerprint reads the live watches
(`drgnx-memo--watched`), so a test that leaves one is named by `test --leaks`.

`(drgnx-memo-census)` returns `((NAME KIND SIZE CAP) …)` for every memo and cache; `bin/drgnx test --soak` prints it
after each round and fails when a cache's SIZE passes its CAP. Tests: `test/unit/core-memo-test.el` (prefix
`drgnx-memo/`; the 0-allocation tests byte-compile the library's functions in place first, because the tests run on
source and an interpreted call conses).

## Views (`wb/drgnx-view.el`)

A view draws a buffer as keyed rows: one row per KEY, from START (the view's only marker) to the end of the buffer.
**Never erase, mark:** code that changes the model only marks the view (a hash put or a queue push, plus a timer
arm: cheap enough for a process filter), and the draw applies the marks in place, from the view's timer, only while
the view shows. A dirty row is deleted and inserted again at its integer start, a growing row gets only its new
characters, removed rows are deleted one by one. Row starts are integers relative to START; no row has a marker.
Undo is off.

### Declaring a type

```elisp
(drgnx-view-define 'my-list
  :render #'my-list--row          ; KEY → "text\n", or (BODY . SUFFIX)
  :grow #'my-list--grow           ; KEY BODY-LENGTH → the new characters, or nil to render again
  :sync #'my-list--sync           ; VIEW → marks (usually `drgnx-view-sync-rows')
  :slice 0.004                    ; draw in slices (nil: all at once)
  :key-test 'eq)                  ; or `equal' (the default)
```

`drgnx-view-define` returns NAME and stores a `drgnx-view-type` in `drgnx-view--types` (the fingerprint reads its
names). SLICE is nil or at most `drgnx-view-slice` (0.004 s); DELAY is the throttle (nil: `drgnx-view-delay`, 0.1 s;
0: the next timer pass); FOLLOW-TAIL keeps a window at the end; PATCHED (VIEW KEYS) runs after a draw with the keys
it drew or grew, to put the view's own overlays back. A definition made in a module's setup pushes the undo
`"view type NAME"`. A view looks its type up by name at each draw: once the type is removed (its module turned off)
the view draws nothing more, and a redefinition (the module on again, a reload) is picked up. No view is tracked.
`(drgnx-view-type-p NAME)` is non-nil while NAME is defined (a mode that attaches a module's view checks it first).

**RENDER** returns a string ending in a newline, or `(BODY . SUFFIX)` whose concatenation does: growth goes between
BODY and SUFFIX, and the view remembers BODY's length (`drgnx-view-body-length`). A row may span several lines.
**GROW** (KEY BODY-LENGTH) returns the characters to add at the end of BODY ("" adds nothing), or nil to render the
row again; a row rendered as a plain string, or a type without GROW, is rendered again.

### Attaching

`(drgnx-view-attach NAME &key buffer start)` sets the buffer-local `drgnx-view`, `buffer-undo-list` to t, and makes
START a marker (insertion type nil; default `point-min`). Attach after the major mode: a mode call kills the local
variable. START to the end of the buffer belongs to the view: text there that is no row is deleted by the first draw
(the self-check below). When START is `point-min` the buffer becomes read-only; otherwise each drawn row gets
`read-only t` and `front-sticky (read-only)`, so typing at START, inside a row, between two rows or after the last
row is refused (`text-read-only`), while text above START (replace's widgets) stays editable. A widget field that
ends exactly at START cannot grow at its end: end the text above START with a newline. Attaching also puts
`drgnx-view--buffer-shown` on the buffer's own `window-buffer-change-functions`. Attaching again removes the old
view's rows first and releases its marker.

### Marks

| Call | Meaning |
|---|---|
| `(drgnx-view-reset VIEW KEYS)` | a new row set: every row goes, KEYS are appended (earlier pending changes are dropped) |
| `(drgnx-view-append VIEW KEYS)` | new rows at the end |
| `(drgnx-view-insert VIEW KEYS &key after)` | new rows right after AFTER, a drawn or pending key; nil: at the start; any other key: at the end |
| `(drgnx-view-remove VIEW KEYS)` | rows go (a pending row's followers take its place) |
| `(drgnx-view-dirty VIEW KEYS)` | rows to render again; KEYS t: every row, patched, never erased |
| `(drgnx-view-grow VIEW KEY)` | the row only grew at the end of its BODY (a pending `dirty` wins) |
| `(drgnx-view-touch VIEW)` | the model changed: SYNC runs at the next draw |

A key already shown or pending is left where it is by `append` and `insert`. Structural marks queue as
`(OP KEYS AFTER)` and are worked out in order at draw time, so a burst of marks costs one pass. Every mark arms the
view's draw (`drgnx-view--arm`); nothing draws from a mark, so a mark from a process filter, a sentinel or
`post-command-hook` only marks.

`(drgnx-view-sync-rows VIEW KEYS SIG)` is the SYNC helper: it diffs the ordered KEYS against the drawn and pending
rows. A row whose `(funcall SIG KEY)` is not `eq` to the signature stored at the last sync is dirty (a vector is
compared element by element, with `eq`, so a fresh vector of the same values is unchanged). New keys are inserted,
missing ones removed; a row that moved (outside a longest run kept in order) is removed and inserted, and when more
than half the rows moved, or KEYS share no key with the rows (a new row set: another file's Outline), the view is
reset instead. A reset appends the new rows after the ones that go, so window start and point (Keeping places) fall
to the first new row: a new row set starts at the top. (Inserted at the start instead, they fell back to the last
new row: UI audit #3.)

### Drawing

A draw (`drgnx-view--draw`) runs SYNC when touched, the self-check, then two steps:

1. **The fold** applies the structural marks to the row vectors only; the buffer does not change. A row that goes
   stays as an entry marked `gone`, a new row is an empty entry marked `new`. The vectors are rewritten in place
   when new rows only go at the end (appends and removals), and grown by doubling only when full; an append to a long
   view copies nothing. Otherwise (an insert before a row that stays) fresh vectors are made. Marks that only add
   rows at the end (no row goes) fold in `drgnx-view--fold-tail`, which visits only the new rows: the entries already
   there, rows left to delete between slices included, stay as they are (`drgnx-view/an-append-folds-only-the-new-tail`
   counts the entries a fold visits).
2. **The sweep** works entry by entry in buffer order with one running shift of the starts: `gone` is deleted,
   `new` rendered and inserted, a dirty row deleted and inserted again at its integer start, a growing row gets an
   `insert` before SUFFIX. Dirty marks are moved onto the entries first (`patch` wins over `grow`). When every entry
   is done, the empty entries are dropped and the index follows the rows that moved.

It returns the number of rows drawn, grown or removed, clears the modified flag and calls PATCHED. It binds
`inhibit-read-only` and `inhibit-interaction`. A RENDER or GROW that signals draws the row `⚠ KEY: MESSAGE` in the
`error` face (KEY printed to 60 characters); the first error of a view (also from SYNC or PATCHED) is pushed onto
`drgnx-signal-errors` as `"view NAME: MESSAGE"` (kept to 20), later ones are not recorded again. Errors are never
raised. Between two slices the vectors always describe the buffer: `key-at`, `row-start` and the self-check stay
right while work is left.

`(drgnx-view-draw-now VIEW)` draws everything at once, even when the view is hidden (`g` and tests); it returns 0
for a view object no longer attached to its buffer, or whose type was removed.

**Self-check:** before a draw, when the region (START to the end of the buffer) is not as long as the entries, a
foreign edit moved them: the view deletes the region, draws every row again before the pending changes, and counts
a `:full-draws`.

### Drawing live: the timer, the frame budget, visibility

**The timer.** A mark arms `(drgnx-timer-soon (cons 'drgnx-view BUFFER) DELAY #'drgnx-view--draw-buffer :args
(list BUFFER) :min-interval DELAY :owner BUFFER)`: one draw DELAY after the first mark of a burst, at most one per
DELAY. A type with DELAY 0 arms `soon` with 0 and no min-interval. A slice that leaves work re-arms a second key,
`(drgnx-timer-start (cons 'drgnx-view-more BUFFER) 0 …)`, so the throttle never delays the next slice. A mark made
during a chain arms nothing (`--arm` returns while the continuation is pending): the next slice takes it, so one
view never draws two slices in one gap; re-arming the continuation also cancels a throttle armed during that draw.
A chain broken by hiding leaves no timer, and showing the view arms it again. Both keys are owned by the buffer
(killing it cancels them). Marks made by the view's own SYNC arm nothing (that draw takes them).

**The frame budget: one deadline, no queue, no priority.** A type with SLICE draws one slice per timer firing. The
slice's deadline is `drgnx-view--deadline` when it is still ahead of `(drgnx-timer-now)` (another view drew in this
timer pass and left time), else now + SLICE. Every 8 rows (`drgnx-view--check-every`; a clock read boxes a float)
the slice stops when the deadline has passed or `input-pending-p`. The first check comes after 8 rows, so a slice
draws at least `min(8, work)` rows, and its rows are a multiple of 8 except the last. Views ripe in one timer pass
share the deadline while it is unspent: a view that finishes early leaves the next the rest of the slice. A view
that finds the deadline already spent starts a fresh one, so N sliced views that each use a whole slice cost
N × SLICE in one gap; the spec's "at most 4 ms per gap for all views" needs a timer-pass identity (the store,
Task 15). Views are not queued or ranked: each one's timer fires in turn. Each slice draws the **visible rows first** (for each window on a visible frame, the
entries from the one at `window-start`, `window-body-height` of them), then the rest, each sweep in buffer order.
`:slices` counts the slices of SLICE types and `:max-slice-rows` the most rows one drew. When a draw leaves no view
with work (and the view is not stale), the gap is quiet: `drgnx-gc-gap` runs (when `drgnx-gc` is loaded).

**Visibility (before the store).** `(drgnx-view-shown-p VIEW)` is non-nil when a window on a visible frame shows the
buffer, as `get-buffer-window` with `'visible` answers but without its window list: it walks the frames `next-frame`
reaches from the selected one and their window trees, allocating nothing. (That is the selected frame's terminal: a
view shown only on another terminal counts as hidden until a window change there.) The view keeps the last answer
in its `shown`. A timer draw of a hidden view sets `stale`, adds 1 to `:stale-skips` and returns: **a hidden view
draws nothing and allocates nothing**. While it is stale its marks arm no timer (they cost a hash put and the frame
walk). When a window starts showing the buffer, `drgnx-view--buffer-shown` (on the buffer's own
`window-buffer-change-functions`, which redisplay runs) arms the draw of a stale view; a mark on a stale view that
shows again does too. Store Task 15 replaces this with the store's visibility.

### Keeping places

A draw keeps the buffer's point and, for each window showing the buffer (all frames), its start and point on their
row. It records each as an entry and an offset into it after the fold, and puts it back after the sweep: an entry
that was deleted falls to the next row (the previous one at the end), an offset longer than the row is clamped to
its last character, a position above START stays where it is. A point at the end of the rows stays at the end of
the last row, or, for a FOLLOW-TAIL type, at the end of the buffer, so it follows appends. The windows are moved
inside `drgnx-wb-with-owned-windows`, with `set-window-start W POS t` and `set-window-point`, so the jank guard sees
the view's own windows move.

Buffers that are not views keep places with the same idea:

```elisp
(drgnx-view-with-kept-windows (:key-at #'my-key-at :pos-of #'my-row-start)
  (erase-buffer)
  (my-insert-everything))
```

`(drgnx-view-save-places KEY-AT)` returns the buffer's point and each showing window's start and point as `(KEY
OFFSET LINE)`, KEY being `(funcall KEY-AT POS)` and OFFSET the distance from the start of KEY's row (the first line
above POS with the same key). `(drgnx-view-restore-places PLACES POS-OF)` puts each back at `(+ (funcall POS-OF KEY)
OFFSET)`, or at the start of LINE (clamped) when POS-OF returns nil; dead windows are skipped, and the windows move
inside `drgnx-wb-with-owned-windows`. The macro is save, BODY, restore, and returns BODY's value.

### Reads

`(drgnx-view-key-at &optional POS)` (the current buffer's view; a binary search on the starts that allocates
nothing), `(drgnx-view-row-start VIEW KEY)`, `(drgnx-view-row-count VIEW)` (rows in the buffer; between slices, rows
still to delete count), `(drgnx-view-pending-p VIEW)` (marks not drawn, or work left by a slice),
`(drgnx-view-body-length VIEW KEY)`, `(drgnx-view-shown-p VIEW)`, and `(drgnx-view-stats &optional VIEW)` →
`(:rows-drawn :rows-grown :appended :removed :slices :max-slice-rows :full-draws :stale-skips)`. `:rows-drawn`
counts every row rendered (patched, inserted or appended, an error row too); `:rows-grown` the rows that took GROW's
text; `:appended` the rows added; `:removed` the rows deleted. Without VIEW it sums every live view
(`:max-slice-rows`: the largest).

### Consumers

- **The Search view** (`modules/tools/drgnx-replace.el`, type `replace-results`, defined with its sidebar section): DELAY 0,
  SLICE `drgnx-view-slice`, `eq` keys. A match's key is its plist; a file's header is `(drgnx-replace-file . FILE)`,
  made once per search. Arrivals append (a new file after its header) or insert after the file's last row; a new
  replacement text marks every match row dirty (headers stay); a file searched again removes its old rows and inserts
  the new ones after its header, marked dirty for its box; a new search resets the view. PATCHED updates the status
  line. Tests: `drgnx-replace/` in `test/unit/mod-replace-view-test.el`, `drgnx-view-ui/` in `test/ui/view-ui-test.el`.

- **The agent transcript**: `tools/agents` defines `agent-transcript` in its setup (`modules/tools/drgnx-agents-ui.el`; `:follow-tail t`,
  `:key-test 'eq`, the default DELAY and SLICE). Its rows are `:commands`, each entry plist that shows something, each
  permission and review plist, `:status` and `:queue`. An `agent` entry renders as `(TEXT . "\n\n")` and a `thought` as
  `("… " TEXT . "\n")`, so a streamed chunk is a GROW of the text after BODY-LENGTH. The agent's process filter only
  touches the view (`drgnx-agents-ui--changed`). SYNC has a fast path: when the session's lists are `eq` to those of
  the last sync, the entries, permissions and reviews lists are as long (a `delq` keeps the head when the first item
  stays), each queued message is the same (a requeue replaces one in place) and no tool or plan entry still running
  changed (they change in place: compared by signature), it only compares each running text's length with its drawn
  body and marks a grow; otherwise `drgnx-view-sync-rows` diffs the rows. An answer's or a thought's signature is its
  type alone, so the turn's end (`:done`) draws nothing again. A grow draw allocates the same on a 4 kB and a 400 kB
  answer (`drgnx-agents-ui/grow-allocation-is-independent-of-size`). The footer rows follow the entries, so a new
  entry while a turn runs is an insert, not an append.

  The model keeps streamed text as chunks (`core/drgnx-agents.el`): a running `agent` or `thought` entry has `:chunks`
  (newest first) and `:length`, so appending a chunk costs a cons whatever the answer's size
  (`drgnx-agents/a-chunk-costs-the-chunk-not-the-answer`). `(drgnx-agents-entry-text E)` joins them into `:text` once and
  keeps it until the next chunk; `(drgnx-agents-entry-length E)` reads the length without joining; `(drgnx-agents-entry-tail
  E FROM)` builds the text after FROM from the newest chunks only (the transcript's GROW). Code that reads an answer's
  whole text goes through `drgnx-agents-entry-text`. The turn's end, `agents/get` and the hub's `agent-entries` flush
  join every entry first (`drgnx-agents-join-text`), so a done entry and the wire carry a whole `:text`.

- **The Agents list**, a view with no rows, is `agents-list` (`:render #'ignore`, `:sync #'drgnx-agents-ui--list-print`,
  the default DELAY): the buffer is a `tabulated-list-mode` buffer whose text belongs to tabulated-list, and the view
  gives it the throttle, the visibility check and the stale mark. A session's change (`drgnx-agents-ui--changed`) and
  the 30 s tick (`agents-ui-tick`) only touch the view; SYNC runs `drgnx-agents-ui--update-lines` inside
  `drgnx-view-with-kept-windows` (key = `tabulated-list-id`): a line whose id and columns are unchanged is not touched,
  a changed one is replaced, gone and new ids are deleted and inserted, so a window stays on its session when lines move.
  (`tabulated-list-print` with UPDATE cannot do this: it needs a sort key and keeps a line of the same id even when its
  columns changed.) The view's START is the only marker; SYNC moves it to the end of the buffer after each update,
  because the self-check would otherwise take the list's text for foreign text and delete it. A hidden list draws and
  allocates nothing, and `drgnx-agents-ui-list-buffer` (the placeholder, `agents-view`) touches and draws it now.
  The tick itself runs only while the list shows: `drgnx-agents-ui--tick-update`, subscribed (idle lane) to
  `windows-changed`, `pane-shown`, `pane-hidden` and `frame-removed`, starts `agents-ui-tick` (owner `tools/agents`,
  30 s, repeating) while a window in `drgnx-state-windows` of any recorded frame shows `*drgnx Agents*`, and cancels it
  when none does (a running tick keeps its phase). It reads the records and ignores the event's data; the setup
  also calls it once. The list may show in the dock or in an editor window, so it checks buffers, not pane kinds. A
  window on an iconified frame still counts (the store has no event for visibility; the tick only marks, and the view
  draws nothing there). The view's own check stays the one that hides the drawing. Tests: `drgnx-agents-ui/the-tick-runs-only-while-the-list-shows`,
  `…/hiding-stops-the-tick`, `…/the-list-in-an-editor-window-ticks-too`.

- **The Outline** (`wb/drgnx-outline.el`) is the view type `outline` (DELAY 0, `equal` keys, PATCHED `drgnx-outline--mark-current`), attached to its
  buffer when `drgnx-outline--buffer` makes it. A refresh builds imenu's index once and makes the rows integers:
  `drgnx-outline--flatten` reads each marker's position and releases it with `(set-marker M nil)`, so no imenu marker
  stays in the source buffer (PERF-M1; the test counts them over 50 refreshes of 2,000 definitions). Row keys are
  `(NAME DEPTH ORDINAL)`, ORDINAL counting the earlier rows with the same name and depth; a notice is the single row
  `(:notice TEXT)`. `drgnx-outline--refresh-1` fills `drgnx-outline--rows` (vectors `[NAME DEPTH POSITION KEY]`) and
  `drgnx-outline--table` (KEY → row), then calls `(drgnx-view-sync-rows view KEYS #'drgnx-outline--sig)`. The signature is
  whether the row is a group, so an edit that only moves definitions redraws no row, and a new definition draws one.
  The view keeps the Outline's point and window start on their row. The current-definition overlay is put back after a
  draw by PATCHED. The follow-the-edit timer is the layer's key `outline-refresh` (`drgnx-timer-soon`, idle, delay
  `drgnx-outline-delay`, owned by the Outline's buffer once it exists). Tests: `test/unit/wb-outline-test.el`,
  `test/unit/wb-outline-edge-test.el` (prefix `drgnx-outline`).

- **The Work tree** (`work-tree`, `modules/tools/drgnx-work-ui.el`; DELAY 0): row keys are node ids (a node the tree
  shows twice, as a commit under two tasks, has its parent's key appended from the second time on). SYNC
  (`drgnx-work-ui--render`) walks the open tree into the ordered keys and calls `drgnx-view-sync-rows`; a row's
  signature is the vector `[(sxhash-equal LINE) DEPTH FOLD]` (a database's strings are never `eq`, a fixnum is).
  Folding, the filter and a scan's sentinel only touch the view; point and window start stay on their row.
  `drgnx-work-ui-buffer` draws a new buffer at once and only marks an existing one.

- **The Work graph** (`work-graph`, `modules/tools/drgnx-cockpit.el`; DELAY `drgnx-cockpit-redraw-delay`, `equal`
  keys): hub events, agent sessions, scans and themes only touch the view; SYNC compares a cheap key before it builds
  the model. Outline rows are the lines keyed by node, `(:node ID N)`; the drawing's rows are its head lines and its
  bands of image slices, `(:head N)` and `(:band N)`. Each row's signature is a generation that moves only when its
  text changed (`drgnx-cockpit-row-cell`). A drawing whose boxes did not move changes band images in place and marks
  nothing. Its check timer runs only while its pane shows (the store's `pane-shown` and `pane-hidden`).
  [cockpit.md](cockpit.md#redraws) has the rest.

- **The cockpit's feed and parts** (`modules/tools/drgnx-cockpit-feed.el`, `-cards.el`): What happened
  (`cockpit-happened`: `:head`, a row per event line, `:footer`), the timeline (`cockpit-timeline`: `:head`, a row per
  agent's chips) and What needs you and the decision log (`cockpit-cards`, DELAY 0: a row per part of the hub's answer,
  kept while what it shows of it is the same). Events touch the feed's views; a hub answer marks the parts'. A new
  event draws one row in each feed pane. [cockpit.md](cockpit.md) has the rest.

### The invariant

`(drgnx-view--check VIEW)` is nil when the starts are the entries' actual extents: entry 0 starts at 0, every
non-empty entry ends with a newline just before the next start, an empty entry is a row to insert or a deleted one,
the index points at each row and row to insert (never at a row to delete), and the last start is the end of the
buffer. Otherwise it names the first fault. Tests: `test/unit/wb-view-test.el` (prefix `drgnx-view/`, including 200
seeded random marks checked against a plain list and an append that stays in place) and
`test/unit/wb-view-live-test.el` (prefix `drgnx-view-live/`: the timer, visibility, slices, places, all on the
virtual clock; slices replace `drgnx-timer-now` with a clock that steps per read, and since batch Emacs runs no
redisplay the visibility tests call `drgnx-view--buffer-shown` as redisplay would). Helpers in
`test/fixtures/view-fixture.el` (`drgnx-view-test-with-type`, `drgnx-view-test--text`, `drgnx-view-test--expected`,
`drgnx-view-test--alloc`).

### Mark, don't erase

A live view is never redrawn by throwing its rows away: `erase-buffer`, `tabulated-list-print` without UPDATE and
`delete-region` to `(point-max)` lose the scroll position, the selection and every row's identity, and cost a full
redraw for one changed row. Code that learns of a change marks the view. The lint
`drgnx-lint/views-never-erase` (`test/unit/lint-render-test.el`) fails on such a call in `wb/` and `modules/`
unless `test/lint-render-allowed.eld` lists it as `(:file F :in DEFUN :what CALL :kind KIND :why STRING)`, one entry
per (file, defun, call) with `:n` for more than one site. KIND is `document` (drawn once, on a user action),
`listing` (Explorer and Buffers, styled by jit-lock), `job-window`, `recovery` (the view core's own reset after a
foreign edit) or `migrate`, a live view whose `:until` names the task that moves it onto the view core. Counts can
only fall: the task that rewrites a site deletes its entry, and `drgnx-lint/no-stale-render-allowlist-entries` fails
on an entry that matches nothing. In the same way `drgnx-lint/garbage-collect-only-in-the-gc-owner` fails on
`garbage-collect` or an addition to `post-gc-hook` anywhere but `core/drgnx-gc.el`, `harness/` and `test/`: one
owner decides when to collect.

## Modal core (`drgnx-modal.el`)

The engine-neutral half of modal editing; evil plugs into it (the `editor/evil` module, below), another engine could.
Nothing in it needs evil, and `test/unit/modal-core-test.el` drives it with a fake engine.

- **Maps.** `drgnx-modal-leader-map` holds the leader keys (`SPC …`, `C-w …`), `drgnx-modal-panel-map` the keys
  that exist only in panels. Both are emulation maps (`drgnx-modal--leader-alist`, `drgnx-modal--panel-alist`),
  switched per buffer; `drgnx-modal-order-alists` puts them in front of the engine's in
  `emulation-mode-map-alists` after `drgnx-keys--everywhere-alist` and before the AI ghost text's (the ghost's has
  its place whether or not it exists yet; the everywhere alist always gets the first place, and is off while there are
  no `:everywhere` keys: `drgnx-keys--set-everywhere` turns it off and takes it out until the next ordering), and `drgnx-modal-sync-engine` calls it after an engine starts.
  A module whose keys must beat the engine's too (Esc and `q` closing a pane, the quick-help card) adds its alist's
  symbol to `drgnx-modal-front-alists` when its map comes on and calls `drgnx-modal-order-alists`: those go right
  after the panel alist, before the ghost text's.
- **State.** An engine calls `(drgnx-modal-set-state STATE)` on every change (`normal insert visual visual-line
  visual-block replace motion operator emacs`, nil when no engine runs in the buffer). The leader map is on in
  `normal`, `motion` and the visual states, and in a panel's `emacs` state; the panel map only in a panel's `emacs`
  state. A buffer whose keys go elsewhere sets `drgnx-modal-keys-off` (buffer-local) and calls
  `(drgnx-modal-set-state drgnx-modal-state)`: neither map is on there in any state (the Live view does it while you
  drive the page, so `SPC`, `j` and `k` reach the page). The switches are buffer-local and are dropped with the
  major mode, so an engine calls `drgnx-modal-init-buffer` (the buffer's `drgnx-modal-initial-state`: emacs in forms and panels, insert in input
  buffers, else normal) in every buffer when it starts and after each major-mode change (or mirrors its own state with
`drgnx-modal-set-state`; the minibuffer is never modal: `drgnx-modal-init-buffer` leaves it alone). Panels, forms and input buffers are told apart by `drgnx-modal-panel-modes`, `-form-modes` (fields you
  type in: no modal keys) and `-input-modes` (shells and message buffers: start in insert or emacs state), with
  `drgnx-modal-panel-p`, `-form-p` and `-input-p`.
- **Indicator.** `(drgnx-modal-mode-line)` returns the state name (` NORMAL `, ` V-LINE `, …) in
  `drgnx-modal-normal`, `-insert`, `-visual` or `-emacs`, which inherit theme faces. It is one self-contained
  construct, `(:eval (drgnx-modal-mode-line))`, that any mode-line layout can place;
  `drgnx-modal-indicator-on` / `-off` add and remove it at the front of the default `mode-line-format`. The strings
  are made once (`drgnx-modal--indicator-texts`); redisplay only looks one up.
- **Typing.** `(drgnx-modal-typing-p)` says whether a printable key types in this buffer: no engine runs here, or
  the state is insert, replace or emacs. Code that passes a key on to the buffer (a closing key) asks it instead of
  naming an engine.
- **Selection.** An engine sets `drgnx-modal-selection-function`; `(drgnx-modal-selection)` returns
  `(BEG . END)` from it, else from the active region, else nil.
- **Engines.** `(drgnx-modal-define-engine NAME :module M :start F :stop F)` registers one; called from a module's
  setup it records its undo, `(drgnx-modal-undefine-engine NAME SPEC)`, which stops the engine first when it runs (as
  a sync stops one: its stop, then every buffer's state cleared) and removes the definition while it is still SPEC.
  `drgnx-modal-engines` is one of the fingerprint's registries. A key profile asks for
  an engine with a top-level `:modal (:engine NAME :leader KEYS :default-map … :maps …)` (keys/vim.eld);
  `drgnx-modal-sync-engine` starts the engine the current layers need (once) and stops any other (a stop clears every buffer's state and
  removes the indicator, so `SPC` types a space again; an engine's start turns the indicator on), and
  `drgnx-modal-running` names it. `(drgnx-modal-mixed-p LAYERS)` is non-nil when a layer is of a profile without
  `:modal` (a Vim stack mixed with another editor's keys); `drgnx-modal-sync-functions` are called with the layers
  at the end of every sync, started or not. `drgnx-modal-suspended` (one element: the layers at the time) keeps the engine off
for those layers, however often the keys are applied again (Toggle Modal Editing); other layers end it. `:maps` says, per keymap, the states a key bound there must also work in
  (the key resolver reads it); `drgnx-modal-where` names a map for the key sheet ("" for the leader map, whose keys show plain; with VERBOSE it
  says where the leader works, from `:maps`: "normal, visual, motion state and panels", the Shortcuts "where" column).
  `drgnx-modal-default-notes` are lines the key sheet and `keys-report.eld` append to the conflicts: what the modal keys
  take from Emacs' defaults that the resolver does not report without an Emacs layer (the Leader Menu on `M-SPC`
  over `cycle-spacing`). `keys-report.eld` also carries `:modal (:engine :module :running :pending :suspended)` and
  `:leader-menu-key`, and is written again when the engine starts or stops (while modal editing is toggled off
  `:engine` is nil and `:suspended` t, and the leader's which-key labels go); `:module` is the engine's module (the
  doctor runs without the modal core); `:pending` is `:pending-layers` of keys.eld, read as data. The doctor's `modal`
  check reads them: "modal editing is off for this session" while toggled off.
- **Where keys go** (`core/drgnx-keys-modal.el`, pure, used by `drgnx-keys-resolve`). `drgnx-keys-modal-leader-p`
  tells a leader key (`SPC f f`, `C-w h`) from the rest; `drgnx-keys-modal-key-map` binds a leader key in the
  profile's `:map` (`drgnx-modal-leader-map`) whatever the entry says, any other key in the entry's map, the
  command's, `:default-map`, else the profile's; `drgnx-keys-modal-states` gives the states a `:maps` keymap works
  in; `drgnx-keys-modal-of-stack` finds the stack's modal layer (a `keys.eld` leader key goes in its leader map).
  A modal profile's entries for commands outside its layer's scopes are **extras**: their keys in a `:maps` keymap
  are bound next to the command's own layer's keys, never replacing them. `drgnx-keys-after-apply-functions` (abnormal
  hook, the layers) runs at the end of every `drgnx-keys-apply`; the core adds `drgnx-modal-sync-engine` to it.
- **Claims per state** (`drgnx-keys-modal-claims`). When `drgnx-keys-modal` loads it registers
  `(eval-after-load 'evil …)`, which copies evil's state maps named in `:maps` into `drgnx-keys-modal-snapshots`
  before any binding drgnx defers to evil's load (a map not defined is skipped). `drgnx-keys-resolve :snapshots`
  (`drgnx-keys-apply` passes that variable) meets every other layer's `global-map` binding with what a snapshot binds
  on its key (or a prefix of it, or keys under it), and every `global-map` or panel-map binding
  (`drgnx-keys-modal-panel-maps`) with the leader and panel maps' bindings of the resolution; without snapshots the
  `:claims` with STATES stand in, each on the engine maps whose states it covers. In a mixed stack there is no
  insert-state claim (Vim's insert keys are off there). The binding is kept; the conflict carries `:states` and
  `:elsewhere t`. A binding of a higher rank gets `:also` (the engine maps), which `drgnx-keys-apply` binds through
  `drgnx-keys--apply-binding` and records in `drgnx-cmd-bound`, so `drgnx-keys--restore` undoes it — unless the
  engine map's key now differs from the snapshot and is not empty (`drgnx-keys--theirs`: the user's own binding, kept
  and reported as a conflict); leader or panel keys it beats are dropped and each named among the losers. In panels the leader and panel maps always win (they are above the panel's own map).
- **Commands.** `modal-leader` (Leader Menu) reads the leader's keys from any state: a transient map holding the
  leader's `SPC`, and `SPC` read again as if typed (`(no-record . 32)` in `unread-command-events`: in the command
  keys which-key reads, but not in a keyboard macro being recorded, which would replay `SPC SPC`), so which-key shows the `SPC` popup with the leader's labels (`+File`, the command titles).
  `panel-next` / `panel-previous` (Next / Previous Row, bound in the panel map) run the panel's own `<down>` /
  `<up>` binding, else `next-line` / `previous-line`, so a panel keeps its row movement.

## Choosing a modal stack (`drgnx-modal-choose.el`)

A key stack with a modal profile (Vim) needs its engine, and the engine's module is off until chosen.
`drgnx-modal-prepare LAYERS &optional INTERACTIVE` is what Keyboard Profile… and onboarding's Look and Keys call before
they switch, and it returns `ready` (no engine needed, or it is loaded, or it is installed and this process runs no modules: the CLI), `started`, `installed` (one
question, then `drgnx sync` as a job, then a start), `declined`, `pending` or `(fail REASON LOG)`. It turns the engine's
module on (`drgnx-modal-set-module`, which also turns every other engine module off for a stack without a modal profile;
the table is `drgnx-modal-engine-modules`) and asks only when INTERACTIVE and `(drgnx-guard-automatic-p)` is nil; anything
else records `:pending-layers` in keys.eld without asking and writes `keys-report.eld` (only when keys were applied in this
process). The question, the sync and the start run inside `unwind-protect`, so a quit or an error turns the module back off
unless it was on before. `drgnx-modal-apply-pending` runs at the end of `drgnx-init`, after `drgnx-keys-apply`, and
switches a pending stack whose engine has loaded (it never asks and catches its errors). The caller switches the keys only
on `ready`, `started` or `installed`, and saves the layers after the engine runs, so keys.eld never names a Vim stack
without evil. `drgnx-modal-engine-start-now` runs the module mid-session through `drgnx-modules--run-one`; going back to
another stack stops the engine but evil stays loaded until the restart (module teardown owns unloading).

## The Vim engine (`modules/editor/drgnx-evil.el`)

Module `editor/evil` (`:default 'off`, startup stage; packages `evil`, `evil-collection`). `drgnx-evil-setup` sets
`evil-want-keybinding` nil and `evil-want-C-u-scroll` t before `(require 'evil)`, then `drgnx-evil--settings` applies the
module defaults with `drgnx-module-set`, through each option's setter as `setopt` does (`evil-undo-system` `undo-redo`,
`evil-search-module` `evil-search`, `evil-want-minibuffer` nil, `evil-mode-line-format` nil; the user's `setopt` in
config.el runs later and stays when the module is turned off), registers the engine with
`drgnx-modal-define-engine` and the command Toggle Modal Editing, and calls `drgnx-modal-sync-engine`. `drgnx-evil-start`
and `-stop` own what the engine adds (hooks, advice, variable watchers, saved variables): the stop takes it all out
again, except the `eval-after-load` entries (`multiple-cursors-core`, `term/xterm`, the initial state of a mode whose
library loads later), which stay and do nothing while the engine is off (each checks `drgnx-evil--active`), and
evil-collection's registrations, which only bind keys in evil's own maps (inactive without evil). A failing start
undoes what it did. When an engine's stop signals, `drgnx-modal-sync-engine` still clears every buffer's state and
the indicator. Turned off, the module's `:teardown` (`drgnx-evil--teardown`) stops the engine through
`drgnx-modal-undefine-engine` — the engine may have started after the setup, when a Vim stack was chosen, so the stop
undoes what its start did — and the module's record gives the options their old values back; evil stays loaded (it
cannot be unloaded), so its tests run in their own Emacs (`drgnx-test-run-isolated`, [harness.md](harness.md)).

- **States.** The core's `drgnx-modal-panel-modes` and `-form-modes` start in emacs state and `-input-modes` in insert
  state (`drgnx-evil--initial-states`, set again when the mode's library loads and when a list grows); every state
  entry hook calls `drgnx-evil--sync`, which passes the state to `drgnx-modal-set-state`.
- **Cursor and terminal.** `drgnx-evil--cursors-on` gives each state a shape from `drgnx-evil--cursor-vars`, never a colour,
  keeps a variable the user set, and panels keep their own cursor. On 31.1 `xterm-update-cursor` is `type` while the
  engine runs, also for terminal frames already live (`drgnx-evil--xterm`).
- **evil-collection and unimpaired.** Registered per mode when the mode's library loads (`drgnx-evil-collection-modes`,
  the flag `no-collection`); the unimpaired keys follow the engine; multiple cursors switch to emacs state through
  `drgnx-evil--mc-hooks`.
- **Insert-state keys.** `drgnx-evil--insert-bindings` is on only in the pure Vim stack (`drgnx-modal-sync-functions` calls
  `drgnx-evil--insert-for-layers`), through `evil-update-insert-state-bindings` (it does nothing when you set
  `evil-disable-insert-state-bindings`).
- **Ex commands and window keys.** `drgnx-evil-ex-routes` (`:w`, `:wa`, `:e`) are redefined with `evil-ex-define-cmd`, keeping
  evil's argument properties; evil's quit and split commands are `:around` advice (`drgnx-evil--advice-pairs`) that call
  evil's own when the workbench is off. In a buffer another program waits for, the quit advice ends the edit first
  (`drgnx-evil-ex--end-edit`): `with-editor-finish` / `-cancel` in a magit commit or rebase message, `server-edit` (or
  `server-buffer-done` for `:q!`) in an emacsclient buffer.
- **AI.** `drgnx-evil--ghost-inhibit` is on `drgnx-ai-ghost-inhibit-functions` (ghost text asks in insert and emacs state
  only) and `drgnx-evil--selection` is `drgnx-modal-selection-function` (the visual selection, a block widened to its lines).
- **Which-key.** The built-in which-key is turned on, with transient maps shown, while the engine runs, and put back at stop.
- **Order.** `drgnx-modal-order-alists` runs after the engine starts and on `evil-local-mode-hook`, because evil pushes its
  maps onto `emulation-mode-map-alists`.

Tests load the real evil from `DRGNX_MODAL_ELPA` and run in their own Emacs ([harness.md](harness.md)).
## The change bus (`wb/drgnx-signal.el`)

The bus is the subscription API for workbench edges (`drgnx-signal-subscribe`); window answers come from the
workbench state store ("The workbench state store", below). `drgnx-signal-editor-window` is the store's `drgnx-state-editor-window`: the
selected frame's MRU editor, per frame and right at once (when the store has none — the frame not observed yet, or
its editor deleted since — it observes the frame first). `drgnx-signal-editor-window-p` is true when
`drgnx-state-window-role` is `editor`: the role table decides, so a module's own strip defines its role
(tools/replace defines `bar`, the find bar, and quick help `quickhelp`, its terminal strip, in their setups). `drgnx-wb-show-in-editor` and the layouts choose the
editor with `drgnx-state-use-editor`.

`drgnx-signal-mode` listens to the raw buffer hooks, and on the store's `now` lane to `windows-changed`,
`editor-changed` and `selected-changed` (`drgnx-signal--store-events`); it emits deduplicated edges after an idle
delay (`drgnx-signal-delay`). There is one idle flush, `drgnx-signal--flush`, for the bus and the store: the store's
idle lane arms it too. It observes the selected frame (`drgnx-state-sync`), makes the store's waiting idle calls
(`drgnx-state--deliver-idle`), then compares the buffer state:

- `editor-changed` gets the *buffer* of the selected frame's MRU editor, only when it is not the one it sent last
  (`drgnx-signal--editor`): `C-x o` between two windows on one buffer is the store's `editor-changed`, not the bus's,
  so Explorer, Outline and Buffers react as before.
- `frame-changed` (data: the frame) follows the store's `selected-changed` when another frame became the selected
  one; only the store's hooks see a frame switch.
- `drgnx-signal-window-functions` (obsolete: subscribe to `windows-changed` on the `now` lane) run from the store's
  observation, before the frame is drawn, as they did from `window-buffer-change-functions`.

The bus no longer adds to `window-selection-change-functions` or `window-buffer-change-functions`. The flush reads
the buffer list only for what a hook said changed. `drgnx-signal--dirty` holds the parts to rebuild, and each part
has a named raw-hook function that sets it:

| Hook | Function | Sets |
|---|---|---|
| `buffer-list-update-hook` (a buffer made, killed, selected or renamed) | `drgnx-signal--set-dirty` | `set` |
| `first-change-hook`, `after-save-hook`, `after-revert-hook` | `drgnx-signal--modified-dirty` | `modified` |
| `after-save-hook` (`write-file` under the buffer's own name makes it a file buffer, with no rename) | `drgnx-signal--set-dirty` | `set` |
| `after-change-major-mode-hook` (`dired-mode` on an existing buffer; internal buffers are skipped) | `drgnx-signal--mode-changed` | `set` |
| `kill-buffer-hook` | `drgnx-signal--killed` | `set` and `modified` |
| `post-command-hook` | `drgnx-signal--post-command` | nothing, unless the current buffer's modified flag or name differs from the cached one |

`set` rebuilds `:set` and `:names` (and `:modified` with them, since the buffers changed); `modified` rebuilds
`:modified`. A part that is not dirty keeps its cached value, so a keystroke that changed no buffer costs the
post-command comparison and a flush that compares only the editor window and its point (a median of about 5 µs with 300
buffers, byte-compiled, against 479 µs when every flush scanned them). Undo back to the saved state and
`set-buffer-modified-p` run no hook, which is what the comparison is for; it covers the current buffer, and a buffer
that becomes current is compared with what the last flush saw of it (two `assq`, no buffer list). With the mode off
nothing says what changed, so a flush called directly (tests, the bench) rebuilds everything. The edges and what they
mean are unchanged. The hooks are added by the mode, so the mode owns them; a module that needs the bus turns the mode
on (see "Global modes are owned by the first module that turns them on" in the safety net above).

## Build (`drgnx-build.el`)

`bin/drgnx build` byte-compiles `core/`, `wb/` and `modules/` in place (`.elc` files are not tracked); with native
compilation available, Emacs then compiles them natively in the background as they load. Compiled drgnx is several
times faster and makes far less garbage. `install.sh` runs it; drgnx sets `load-prefer-newer`, so a stale `.elc`
never shadows newer source. The build must stay warning-free (`test/unit/build-test.el`).

Each file compiles in a fresh batch Emacs (`-Q`, `core/` and `wb/` on `load-path`), as the native compiler compiles
it when a session loads the `.elc`: in one shared Emacs, a library an earlier file's compile loaded (`project`, `cl-macs`,
another drgnx file) hid a missing `declare-function` or `require`, and the native compiler's warning then opened
`*Warnings*` in the user's frame. `drgnx-build-jobs` files compile at once: one per 150 MiB of `MemAvailable` beyond
1 GiB kept free, at most the processor count (`DRGNX_BUILD_JOBS` sets it); a file that takes more than
`drgnx-build-file-timeout` (120 s) is an error. A file's result is read when its process's sentinel has run (Emacs
runs it only after reading what the process left in its pipe), never when `process-status` first says `exit`: under
load that came before the output, and a finished compile looked like one that ended without a result. The whole build takes about as long as the single-Emacs one did (3 s
on 16 cores). Warnings are printed, and the build test fails on any; `bin/drgnx build` exits 1 only on errors, so a
warning a newer Emacs adds never stops an install or an update.

## The Emacs `bin/drgnx` runs in

The shell function `emacs_bin` picks the one Emacs every subcommand uses: `$DRGNX_EMACS`, else the first line of
the data dir's `emacs` (`$DRGNX_DATA_DIR/emacs`, default `~/.local/share/drgnx/emacs`, written by `install.sh`'s
`remember_emacs`) when it names an executable file, then the same of `$DRGNX_CONFIG_DIR/emacs` (where older
installs wrote it), else `emacs`. The files are read as paths, never evaluated. A new subcommand calls
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
| `drgnx-agent-config-vendor-env` | The vendor keys and switches nothing drgnx starts for an agent inherits: the default of `drgnx-agents-scrubbed-env`, and what MCP Test and Hook Test unset (drgnx-agent-check.el reads the customized list when drgnx-agents is loaded). |
| `-home KIND` | The agent's user directory (trailing slash): `$CLAUDE_CONFIG_DIR` / `~/.claude`, `$CODEX_HOME` / `~/.codex`, `$GEMINI_CLI_HOME/.gemini` (gemini 0.64 replaces its home directory with that variable) / `~/.gemini`, `$KIMI_CODE_HOME` / `~/.kimi-code`. An empty variable counts as unset. |
| `-read KIND ROOT`, `-scopes KIND SECTION ROOT`, `-write KIND OP ITEM SCOPE ROOT CALLBACK` | Generic functions (`cl-defgeneric`, `eql` specializers on KIND) each agent file implements: everything configured as `(:rules :items :problems :routes :notes)`; where an add may go, `((SCOPE LABEL FILE)…)`; add/edit/remove/toggle with a callback getting `(:ok t :note S)` or `(:error S)`. |
| `-json-read FILE` | `(:value V :indent N)`: objects are alists with symbol keys in file order, arrays vectors, `:null`, `:false`. A missing or blank file is `(:value nil :indent 2)`; one that does not parse signals `drgnx-agent-config-unreadable` with `(FILE LINE MESSAGE)` (a trailing comma names the comma's line). |
| `-json-write FILE VALUE INDENT [EXPECT]` | Key order as in VALUE, INDENT spaces, a final newline; through `-write-text`, with the file's and the new text's JSON parse as checks. Unreadable files are never written. A VALUE that is not JSON is an error naming its place and type (`Not a JSON value at mcpServers.x.args (a list, expected a vector)`), never its content. |
| `-write-text FILE TEXT CHECK [VERIFY [EXPECT]]` | EXPECT (the text, or the modification time, seen when the caller read FILE): a FILE that differs now signals `drgnx-agent-config-changed` and nothing is touched (Claude Code rewrites `~/.claude.json` often). CHECK (called with FILE's current text) must not signal, else nothing is touched; VERIFY the same with TEXT. TEXT equal to what FILE holds is not written and the backup stays. Then FILE is copied to `FILE.drgnx-bak` (exactly one backup, 0600 whatever FILE's modes: it holds the secrets of before; its temp file is owner-only before the rename), TEXT goes through `drgnx-file-write-text` (a temp file next to FILE, renamed over it) with FILE's modes (0600 for a new file). A symlink is written through; directories it has to make get 0700. The TOML writes use it too. |
| `-secrets SPEC`, `-mask-text TEXT SECRETS` | Every env and header value, and the value of any key matching token, secret, key, password or authorization (case-insensitive; every string inside a list or object under such a key), longer than 3 characters. Also, in `:args`, `:url`, a hook's `:command` and every other string, only the secret part of: `NAME=VALUE` / `--flag=VALUE` with a secret-ish name, `Bearer`/`Basic`/`Token` values, `Authorization:` values, URL userinfo and secret-ish query parameters, well-known token shapes (`sk-`, `ghp_`, `github_pat_`, `xox?-`, `AKIA`, `AIza`, JWTs), the argument after a secret-ish flag, `-p`, `-H`/`--header` and `-e`/`--env`, and 24+ character `:url` path segments. `-mask-text` replaces each by `••••` and keeps the context. |
| `-cheap-status ITEM [ROOT]` | `(ok . DETAIL)`, `missing-command`, `no-url` or `unreadable`, from files and `exec-path` only: nothing is run. A relative command with a slash is the spec's `cwd`'s (relative to ROOT), else ROOT's, else `~/`'s, never `default-directory`'s. The detail is masked like any text shown (a URL keeps its host and path, not its secrets). |
| `-save-backup FILE`, `-json-read-text FILE TEXT` | The one-backup copy used by `-write-text` (public: a CLI write takes its own backup first); `-json-read` for a text already read. |
| `-json-keystr`, `-json-str`, `-json-alist-p`, `-json-cell OBJ KEY`, `-json-get OBJ KEY…`, `-json-set OBJ KEYS VALUE`, `-json-del OBJ KEYS`, `-json-strings`, `-json-string-alist`, `-json-pairs` | Taking apart and changing a parsed JSON object (a path is a list of key strings): a set member keeps its place and a new one goes last; `-json-pairs` turns `(("NAME" . "value")…)` into an object, refusing a value that is not text. Shared by all four agent files. |
| `-json-modify FILE FUNCTION` | Replace the JSON object in FILE with `(FUNCTION VALUE)`: one read, the write refused when FILE changed since, tried once more with the new content, a second refusal signals `drgnx-agent-config-changed`. |
| `-hook-matcher= GROUP MATCHER`, `-error-text ERR ITEM` | A JSON hook group has the matcher (nil and `""` are the same); the message for a failed write: where and why, never the item's data. |
| `-skills-in DIR FROM KIND`, `-new-skill DIR NAME DESCRIPTION` | Items for `DIR/*/SKILL.md` (name and description from the front matter); creates a skill, refusing an existing name. |

JSON that is tab-indented is re-written with 2 spaces; arrays are always written one entry per line.

## Claude Code's settings (`drgnx-agent-config-claude.el`)

The `claude` methods of the three generic functions, and `drgnx-agent-config-claude-routes`. Read: the files below;
write: only the entry that changed, with one backup next to the file. Credential files are never opened; no key is
looked up.
`drgnx-agent-config-claude-hook-events`: Claude Code's hook events, offered by the settings page (other names may be typed).

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
- An edit keeps the members of an entry drgnx does not edit (an MCP server's `oauth` or `headersHelper`, a hook's
  `statusMessage` or `async`): they are merged into the existing object. An MCP entry that has such members is edited
  directly, not through the CLI, so nothing is dropped. If an edit's `remove` worked and its `add-json` failed, the old
  entry is put back by a direct write ("the change failed; the previous entry was put back"); only if that fails too does
  the message point to the backup, which the next command line write then leaves alone until the name is written again.
  The backup is taken only when `claude` will run.
- Switching a skill on removes the `"off"` from the settings files that make it off (local, then project, then user, up
  to the first other value) and names them; every file is parsed before one is written. Switching it off warns when a
  higher-priority file sets another value.
- A server name is letters, digits, `.`, `-` and `_` and cannot start with `-` or `.` (it is a command-line argument);
  other names (spaces) are a drgnx limit: edit them in Claude Code.
- Errors name the file and line, never the entry's data (values are masked with `-secrets` besides).

`(drgnx-agent-config-claude-routes ROOT)` lists one route per Claude Code profile (command `claude-agent-acp`) with its
billing, derived from the provider and not from the profile's name: no `:ai` is the subscription; the OpenRouter
provider `openrouter`; a loopback URL `local`; any other provider (a `:key-env`) `per-token`, the vendor being the
provider's name. `:key-where` names the variable and the keyring host. An `env` entry of a settings file that sets
`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `ANTHROPIC_SMALL_FAST_MODEL` or
`ANTHROPIC_DEFAULT_*_MODEL` is a note ("overrides every profile's route"), by file and name, never the value.

## Kimi Code's settings (`drgnx-agent-config-kimi.el`)

The `kimi` methods of the three generic functions (checked against kimi-code 2.2.0). Read: the files below; write: only
the entry that changed, with one backup next to the file. `HOME/credentials/` is never opened and no key is looked up.
The route is one: Kimi Code's own login (`kimi login`), billing `subscription`.

| What | Where |
| --- | --- |
| Home | `(drgnx-agent-config-home 'kimi)`: `$KIMI_CODE_HOME` (unset or empty: `~/.kimi-code`). |
| User / project MCP servers | `mcpServers` of `HOME/mcp.json` and `ROOT/.kimi-code/mcp.json`. An entry has `command` (stdio) or `url` (http; `transport` "sse" is written for sse); `enabled` false is off; `bearerTokenEnvVar` names a variable. |
| Read only | `ROOT/.mcp.json` (Kimi Code reads it too; Claude Code's page edits it), the enabled plugins' servers (`plugin-ID:SERVER`), hooks and skills (`HOME/plugins/installed.json`, each root's `kimi.plugin.json` or `.kimi-plugin/plugin.json`), and the old kimi-cli's `~/.kimi` (`mcp.json`, `config.toml` hooks, `skills/`) under `:from legacy` with the note "the old kimi-cli's config: kimi-code migrates from it; drgnx does not edit it". |
| Hooks | `[[hooks]]` tables (`event`, `matcher`, `command`, `timeout` 1 to 600) in `HOME/config.toml`, user scope only. Hooks written some other way (an inline `hooks = [...]`) are read only, with `:reason` naming the line. |
| Skills | `HOME/skills`, `~/.agents/skills`, `ROOT/.kimi-code/skills`, `ROOT/.agents/skills`. The format has no off switch: a skill is always on and a toggle is refused. |
| Rules | `HOME/AGENTS.md`, `ROOT/.kimi-code/AGENTS.md`, `ROOT/AGENTS.md` when present. |

Writes are synchronous (the callback runs at once). An MCP edit merges the modelled members (`transport`, `command`,
`args`, `env`, `cwd`, `url`, `headers`, `bearerTokenEnvVar`) into the entry that is there and keeps every other member
(`enabled`, timeouts, `auth`, tool lists, ...); a rename keeps the entry's place. A hook edit does the same for its
table. Each write re-reads the file just before and passes what it read as EXPECT, so a file changed meanwhile is read
again, once; a second change is reported and nothing is written. A file that does not parse is reported with its line
and never written. Errors never show the entry's data. The hook events are the 16 `config.toml` accepts; any other
makes Kimi Code reject the whole file, so drgnx refuses it.

## Codex's settings (`drgnx-agent-config-codex.el`)

The `codex` methods of the three generic functions, `drgnx-agent-config-codex-trusted-p`, `-routes`, `-openrouter-snippet`
and `-add-openrouter`. Formats checked against codex 0.163.0. Credential files (`auth.json`) are never opened.
`drgnx-agent-config-codex-hook-events`: Codex's hook events, offered by the settings page (other names may be typed).
A config.toml that does not parse is a problem "not valid TOML" with its line, never the parser's text (it quotes the file).

| What | Where |
| --- | --- |
| User settings | `CODEX_HOME/config.toml` (`$CODEX_HOME`, else `~/.codex`). |
| Project settings | `ROOT/.codex/config.toml` and `ROOT/.codex/hooks.json`, read only when `(drgnx-agent-config-codex-trusted-p ROOT)`: the user's config has `[projects."ROOT"]` with `trust_level = "trusted"` for ROOT or its repository root. Otherwise they are still read and shown: each item carries `:inactive "Codex ignores it until the project is trusted"` and `:notes` names the file, because trust gates the effect, not the display (drgnx matches ROOT, its real path and the nearest folder with a `.git`; a git worktree has a `.git` of its own, so only its own path counts here, and whether Codex also honours the main checkout's entry is not verified). |
| MCP servers | `[mcp_servers.NAME]`: `command`/`args`/`env` (stdio), `url`/`bearer_token_env_var`/`http_headers`/`env_http_headers` (streamable HTTP; no `sse`), `enabled`. `:headers` holds the literal `http_headers` values (secrets, masked); `env_http_headers` give `:env-headers` (header names) and `:env-header-vars` (the variable names, same order): names are not secrets, so the page shows them as "from $NAME" unmasked. A value there that cannot be a variable name is also put in `:headers`, so it is masked. |
| Hooks | `hooks.json` of the Codex home and of ROOT/.codex (editable, shaped like Claude Code's); inline `[[hooks.EVENT]]` in a config.toml are shown read-only with a note to edit hooks.json. |
| Skills | `~/.agents/skills`, `ROOT/.agents/skills`; off by a `[[skills.config]]` entry (`path` of the skill's `SKILL.md` or directory, `enabled = false`) in the user's config.toml (the state is read from the user's config only, not from a project's). |
| Rules | `CODEX_HOME/AGENTS.md`, `ROOT/AGENTS.md`. |

Writing: a TOML write parses the file first (one that does not parse, or has a duplicate table, is never written), builds
the new text with `drgnx-toml-set-table` / `-set-array-entry` (nothing outside the changed table moves; comments inside
a replaced table do not survive: the backup has them), checks it parses, and goes through `-write-text` with what it read
as EXPECT (one retry when Codex changed the file meanwhile). A server table is rebuilt from the existing one with only the
modelled keys replaced, so `startup_timeout_sec`, `enabled_tools` and other keys stay; a rename is one write. A hook edit
keeps the hook object's other members (`statusMessage`, `async`) and its group's. Toggling an MCP server changes only its `enabled` key in the text (a word swapped or one line added under the header; comments and value forms stay; a table that is not shaped so is rebuilt);
toggling a skill adds, changes or removes its `[[skills.config]]` entry (an entry with other keys only has `enabled`
changed). A project write in an untrusted project works and says Codex ignores it until the project is trusted.

Routes: `(:profile "codex" ... :billing subscription)`, "its own CLI with your ChatGPT login", then one per
`[profiles.NAME]` whose `model_provider` is OpenRouter (the id `openrouter` or a `base_url` on openrouter.ai) with
`:billing openrouter` and `:launch "codex --profile NAME"`. `(drgnx-agent-config-codex-add-openrouter MODEL)` writes
`[model_providers.openrouter]` (`name`, `base_url = "https://openrouter.ai/api/v1"`, `env_key = "OPENROUTER_API_KEY"`,
`wire_api = "responses"`: 0.163 refuses `chat`) and `[profiles.openrouter]` (`model_provider`, `model`) into the user's
config.toml, keeping other keys of those two tables (a `base_url` or `env_key` that differs from OpenRouter's is the user's: kept, and the note says so; only `wire_api = "chat"` is changed); the default stays the ChatGPT login. `-openrouter-snippet MODEL` is
the same two tables as text to paste.

## Gemini CLI's settings (`drgnx-agent-config-gemini.el`)

The `gemini` methods of the three generic functions, and `drgnx-agent-config-gemini-routes` (one route: Gemini's own CLI
with a Google login, `subscription`; the login is never read). Checked against gemini 0.64.0. It uses the shared JSON
helpers of `drgnx-agent-config.el`; only its comment-refusing `drgnx-agent-config-gemini--modify` is its own.

| What | Where |
| --- | --- |
| User / project settings | `HOME/settings.json` (HOME is `.gemini` under `$GEMINI_CLI_HOME`, else `~/.gemini`), `ROOT/.gemini/settings.json`. |
| System (read only) | `$GEMINI_CLI_SYSTEM_SETTINGS_PATH` else `/etc/gemini-cli/settings.json` (macOS: `/Library/Application Support/GeminiCli`), and `system-defaults.json` (`$GEMINI_CLI_SYSTEM_DEFAULTS_PATH`). |
| MCP servers | `mcpServers`. In 0.64.0 `url` plus `type` http or sse is current, `url` alone is Streamable HTTP (the docs say SSE), `httpUrl` is deprecated: read as http, never written. Edits write `url` + `type`. |
| Hooks | `hooks.EVENT[]` = `{matcher, sequential, hooks: [{type, command, name, timeout}]}`; `:timeout` is in milliseconds (`:timeout-unit ms` in the spec). Off by `name` (else the command) in `hooksConfig.disabled`. |
| Skills | `HOME/skills`, `$GEMINI_CLI_HOME-or-~/.agents/skills`, `ROOT/.gemini/skills`, `ROOT/.agents/skills`, extensions' `skills/` (read only). Off by name in `skills.disabled`, the union of all settings files. |
| Extensions | `HOME/extensions/*/gemini-extension.json` (`mcpServers` as `extension:NAME:SERVER`) and `hooks/hooks.json`, read only. On unless `extensions/extension-enablement.json` has a rule for NAME that matches the project (last wins, `!` disables). |
| Rules | `GEMINI.md`, or the names in `context.fileName`, in HOME and ROOT. |

Gemini reads its settings files with comments (JSONC) and keeps them when it writes; drgnx cannot. A file with comments is
read (comments ignored, line numbers kept), its items are read-only, a note says why, and it is never written. A write
changes only the modelled members of one entry (`command`, `args`, `env`, `url`, `httpUrl`, `type`, `headers`; a hook's
`type`, `command`, `timeout`) and keeps every other member in place (`cwd`, `trust`, `includeTools`, unknown keys); it passes
what it read as EXPECT, so a file changed meanwhile is refused. Switching a skill off adds its name to `skills.disabled` of the
user's settings (or the chosen file); switching it on removes it from every writable file that lists it (the project's
file is shared with the team, and the note says so). All those files are checked first (parse, no comments, not listed by the
system settings) and nothing is written if one fails; a later failed write puts the earlier files back and says so. An edit of an
http server that has `httpUrl` keeps `httpUrl` (older Gemini CLIs). Hooks and MCP servers cannot be switched off here. A new server name is letters, digits, `-`
and `.` (Gemini's policy rules misread an underscore).

## MCP Test and Hook Test (`drgnx-agent-check.el`)

The two checks of the agent settings pages. Both run the user's configured command, so they run only from a command
(Test, Test all), never from a timer, hook or sentinel, and never in the editing Emacs. Tests use the mock server in
`test/fixtures/mock-mcp.el` only (stdio modes `ok`, `hang`, `crash`, `flood`, `echo-env`, `fork-child` as
`emacs --batch -Q -l mock-mcp.el -f drgnx-mock-mcp-main MODE MARKER`, plus `error` and `oom`; an HTTP one,
`drgnx-mock-mcp-http-start MODE` with `ok`, `needs-login`, `hang`, `error-body`, `echo-path` and `legacy-sse`, served by
the test Emacs); never the user's servers, hooks or agent homes. The tests run with `DRGNX_JOBS_LAUNCHER=detached`, so
they never create a scope in the user's systemd manager.

| Function | Does |
| --- | --- |
| `drgnx-agent-check-timeout` | 20 seconds for an MCP Test. |
| `(drgnx-agent-check-mcp ITEM ROOT CALLBACK)` | Starts a batch Emacs (`emacs --batch -Q -L core -l drgnx-agent-check -f drgnx-agent-check-main`) inside `systemd-run --user --scope -p MemoryMax=512M -p MemorySwapMax=0` when `(drgnx-jobs-launcher)` is `systemd`, and returns its process. The server's spec (command, args, environment, URL, headers, the secrets to hide) is one line of JSON on that Emacs's stdin: never a command line, never a file. CALLBACK gets `(:status ok\|failed\|needs-login\|timeout :tools NAMES :error STRING :stderr STRING :time FLOAT)`, masked. `${VAR}` and `${VAR:-default}` are expanded for Claude Code and Gemini, as those agents do, and the expanded values are masked too. |
| `drgnx-agent-check-main` | Child side. stdio: starts the server in ROOT with its environment, sends `initialize` (MCP revision 2025-06-18), `notifications/initialized` and `tools/list` (every page), ends the server's whole tree (descendants, its group and session) at the end. HTTP (`http` and `sse` items; Streamable HTTP only): POSTs the same, keeps the `Mcp-Session-Id` and `MCP-Protocol-Version`, reads JSON or SSE answers (an SSE stream the server leaves open is fine). A 401 with `WWW-Authenticate` is `needs-login`, and `:error` says how to log in (`drgnx-agent-check-login-hint`: Claude `/mcp`, Codex `codex mcp login NAME`, Gemini `/mcp auth NAME`). Limits: the timeout; 256 KB of output that is not JSON-RPC (a flood); 4 MB for one message or answer; stderr 8 KB. This Emacs ends the child (and everything under it) 5 seconds after the timeout if it did not. A TLS certificate that cannot be verified is refused (the child cannot ask), so a server with a self-signed certificate fails with a message saying so. A connection that never completes is ended by the 5-second backstop above. |
| `(drgnx-agent-check-hook ITEM ROOT CALLBACK)` | Runs the hook's command with `sh -c` in ROOT (in the same memory cap), the sample event as JSON on stdin, for the hook's timeout (Gemini's is milliseconds) or 60 seconds. The command travels in the environment (`DRGNX_HOOK_COMMAND`, unset before it runs), not on a command line. CALLBACK gets `(:exit N :stdout S :stderr S :time F)`, masked, 16 KB each; a hook that ran out of time has `:exit nil :timeout t`; one that could not start has `:exit nil :error S`. |
| `(drgnx-agent-check-sample-event KIND EVENT ROOT)` | The event as an alist. Claude Code and Kimi Code: `session_id`, `transcript_path`, `cwd`, `hook_event_name` and per event `tool_name` `Bash` with `tool_input` `{"command": "echo drgnx-hook-test"}` (and `tool_response`, `prompt`, `source`, `trigger`, … as the event has them). Codex: the same plus `model` and `turn_id`. Gemini: its own events (`BeforeTool` with `run_shell_command`, `BeforeAgent` with `prompt`, …) and `timestamp`. The Codex and Gemini fields are the builder's table from their documentation, not checked against a running agent. |
| `(drgnx-agent-check-remember ITEM RESULT)`, `(drgnx-agent-check-last ITEM)` | The last result per `(KIND SECTION NAME FILE)` in `(drgnx-state-dir)/agent-checks.eld` (0600), masked, with `:at` (the time). Each write keeps the newest 300 (by `:at`), drops results whose local FILE is gone, then drops the oldest while the printed file would pass `drgnx-file-max-bytes` (`drgnx-agent-check--fit`; the newest always stays), so the reader's cap never makes the file unreadable. |
| `(drgnx-agent-check-results)` | Every remembered result in one read, `((KIND SECTION NAME FILE) . RESULT)…` (the settings page reads it once per drawing). |

Ending a check: the child Emacs and the scope it runs in are named (`systemd-run --scope --unit=drgnx-check-PID-N`); at
the timeout this Emacs runs `systemctl --user kill --signal=KILL` on the scope as an asynchronous process, so the editing
Emacs does not stop (11 ms longest stall measured). The scope name has a random part. The kill is started from the
temp directory (a timer runs in any buffer, whose directory may be gone); if `systemctl` cannot be started or fails the
tree is ended instead; 3 seconds after the timeout the check is over whatever happened (tree ended, a hanging `systemctl`
deleted, the callback called once). A check that ends normally also asks systemd to clear its scope and ignores the answer. Where there is no systemd (or `systemctl` fails) it ends the process
tree: parent, group and session links are read from `/proc/PID/stat` (45 ms for 640 processes; `process-attributes`
needs 320 ms), the tree is stopped, found again until it does not change, then killed. The child ends its server the same way.

Secrets: every string a check hands back is masked, in the members `:error`, `:stderr`, `:stdout` and `:tools` (not the
status, the time or the exit code), with the item's secrets (`drgnx-agent-config-secrets`); the values `${VAR}` (and
Gemini's `$VAR`) were replaced by; the variables a spec names for a bearer token or a header (Codex `bearer_token_env_var`
and `env_http_headers`, Kimi `bearerTokenEnvVar`, sent as `Authorization: Bearer VALUE` and the named headers when set);
and this Emacs's own secret-looking environment, because a server may print its environment: a name with token, secret,
key, password, passwd, authorization, cred, cookie, dsn or pat in it always, a name with only pass, auth or session in it
unless it is `XDG_SESSION_TYPE`, `XDG_SESSION_CLASS`, `XDG_SESSION_ID`, `XDG_SESSION_DESKTOP`, `XDG_SESSION_PATH`,
`DESKTOP_SESSION`, `GDMSESSION`, `SESSION_MANAGER`, `DBUS_SESSION_BUS_ADDRESS`, `XAUTHORITY`, `ICEAUTHORITY`,
`SSH_AUTH_SOCK` or has askpass in it (`drgnx-agent-check--not-secret-names`), and the userinfo of URL values. In a
server's own configuration the names with pass, auth or session count too. Each secret
is also hidden percent-encoded, percent-decoded, JSON-escaped and cleaned (so a secret with a carriage return still matches). Overlapping matches are one range
(`drgnx-agent-config-mask-text`). A short value (4 to 7 characters) with a plain name (`MODE=prod`) is hidden in errors
and stderr but not in tool names. Output is cleaned first (escape sequences, control characters, bytes that are not UTF-8),
then masked, then cut to its limit, so a secret is never split by an escape or cut in two. An HTTP error body is masked
before its first 200 characters are shown, and a JSON-RPC error is cut to 500. A project on a remote host (TRAMP) is
refused. A signal 9 is said to be the memory cap only when the check runs in a scope. Hooks get `CLAUDE_PROJECT_DIR` (Claude Code, Kimi Code, Gemini) and `GEMINI_PROJECT_DIR` (Gemini). An unset
`${VAR}` with no default is passed as written and named in the result (`:unset`, and in `:error` when the check failed).
The only file written is `agent-checks.eld`; the child Emacs writes nothing.

## Doctor (`drgnx-doctor.el`)

`bin/drgnx doctor [--json] [--dev]` asks the Emacs drgnx will use (see above) whether this
machine is ready, and gives a fix for anything that is not:

```
OK    emacs-version        Emacs 31.1                 (30.2: WARN — works, 31.1 recommended; older: FAIL)
OK    native-compilation   native compilation works   (built without it, or libgccjit broken: FAIL)
OK    tree-sitter          tree-sitter available
OK    gui                  graphical build (pgtk)     (terminal-only: OK, with a note)
OK    security             Emacs 31.1 has 3 known issues, fixed in 31.2: CVE-2026-108976, … ; drgnx's guards are on
OK    git                  git found
```

`security` lists the CVEs that apply to this Emacs version (`drgnx-doctor-security-issues`: below each issue's fixed-in
version, with a "partly fixed" note from the version that closes some ways in) and reads the guards from the
`:trust-guards` fact, `drgnx-trust-guards-status`. In a batch doctor (a bare Emacs where drgnx's startup has not run)
the fact gatherer switches `drgnx-trust-mode` on, reads the status and switches it off again, so the answer is about the
guards drgnx's startup installs (Flymake's check, added when Flymake loads, is then marked "not verified in a batch
check"). When the mode is already on, when startup ran (its commands are registered) or inside a session, it reads the
mode as it is: a mode that was turned off is reported off, with a WARN. OK while every guard is on, WARN naming
each guard that is off (and when the guards cannot be read); facts without `:trust-guards` are judged by version alone.

`config-files` (group drgnx) is the fact `:config-files`, a fresh `drgnx-config-read` of every defined file that is not a
project's (after requiring `drgnx-doctor-config-features`). FAIL names each mistake as "FILE line L: TEXT" (the file's
last good copy is in use meanwhile); WARN for a file a newer drgnx wrote; INFO for unknown keys ("a newer drgnx, or a
typo?") and for a file in an older format; otherwise OK, "N files read". The doctor reads and never writes. See
[files.md](../guide/files.md). `checkout-clean` (group drgnx) is the fact `:checkout-init`: `git -C CHECKOUT status
--porcelain -- init/` (`GIT_OPTIONAL_LOCKS=0`, bounded at 5 s). A change there is a WARN, because install.sh's update needs
`init/` unchanged; the fix is to move it to `config.el` or `custom.el` in the config folder and `git checkout -- init/`.
Without a `.git` (not a checkout) the check is absent. `config-dir` (group drgnx) is the fact `:config-dir`, `(:dir
(drgnx-user-dir) :moved (drgnx-paths-config-moved-p))`: WARN while the old `~/.config/drgnx` is used in place of
`$XDG_CONFIG_HOME/drgnx`, with the fix "move ~/.config/drgnx to …"; also WARN, one line per variable, while a path
variable is set to a value that does not count (`:ignored`, `(drgnx-paths-ignored)`: "ignored: not an absolute path:
VAR=VALUE; drgnx uses DIR"); otherwise OK, naming the folder. Hints name the
config folder in use, `(abbreviate-file-name (drgnx-user-dir))`, never a literal `~/.config/drgnx`.

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

A check that returns nil is absent from the results; `drgnx-doctor-run` also takes a group name to run one group.
The **Terminal** group (`terminal`, `terminal-colours`, `terminal-mouse`, `terminal-keys`, `terminal-clipboard`,
`terminal-tmux`, `terminal-ssh`, `terminal-popups`) reads the fact `:terminal`, which `drgnx-doctor-terminal-facts`
gathers: `drgnx-tty-facts` (the environment of the process the doctor runs in; inside tmux one `tmux show`, 1 s),
`:caps` and the fallback rows from the newest entry of `terminal-report.eld` for that kind of terminal, and `:os`.
Check This Terminal (`ui/terminal`) runs the same group with the selected terminal window's own capabilities and its
client's environment. A detail of several lines (the key table) is printed indented. See
[terminal.md](../guide/terminal.md#check-this-terminal).

`claude-adapter` (group Tools): the fact is `drgnx-agents-claude-adapter` (`drgnx-agents.el`), the adapter that the
claude profiles would run, with the name, version and npm prefix read from the `package.json` it links into. The
adapter is never run. The judgement is `drgnx-agents-adapter-problem`, the same one the onboarding Agents step and
the agent start use. The maintained package at `drgnx-agents-claude-min-version` (0.93.0) or newer is OK. The
deprecated `@zed-industries/claude-agent-acp`, an older version, or a program of no known package is WARN. The fix
is an npm command in the adapter's own global prefix, or `drgnx-agents-adapter-advice` when there is none (pnpm,
volta, a project's `node_modules`). None is INFO. A `package.json` is read only when it is a regular file of at most
64 KiB (`drgnx-agents--package-json-max`; a FIFO would block the read); otherwise it is no known package. A
pre-release version is compared without its `-…`/`+…` suffix. Tests: `test/unit/doctor-test.el` and
`test/unit/agents-adapter-test.el`.

The **Desktop** group's `window-manager` row reads the fact `:window-manager`, `(drgnx-platform-doctor-facts
&optional FRAME)` (see [Window managers](#window-managers-drgnx-platformel)); onboarding step 7 shows the same row
for the selected frame. Tests: `test/unit/doctor-wm-test.el`, `test/unit/onboard-wm-test.el`.

`timers` (group drgnx) reads the fact `:timers-report`: `timers-report.eld` and `hub-timers-report.eld` from the
state dir (`drgnx-doctor--timers-report`), which the last session and the last hub rewrite each time a timer stops
after failing 3 times in a row ([Timers](#timers)). OK "no timer stopped"; else WARN `KEY (FN): ERROR; …` with the
report's age, fix "report the error; drgnx starts the timer again at the next start". A report stays until the next
stop rewrites it, so an old one shows its age.

## Window managers (`drgnx-platform.el`)

Emacs cannot move a frame to another monitor by itself under Wayland, and a tiling window manager ignores
`set-frame-position`. An *adapter* knows one window manager (or none): its monitors, which one a frame is on, and
how to move a frame. Nothing here blocks, prompts or signals on an automatic path (frame creation,
monitors-changed, restore): every window-manager call is asynchronous with a deadline.

**Detection** is per frame, from the frame's own environment (`(getenv VAR frame)`, else the daemon's), because
one daemon serves frames from several sessions. `(drgnx-platform-detect ENV WINDOW-SYSTEM)` is pure (ENV is a
function VAR -> value) and tries the adapters in definition order:

| Window system | Order |
|---|---|
| `ns`, and batch Emacs on macOS (`drgnx doctor` in Terminal.app) | `ns` |
| `pgtk` | `sway` (`SWAYSOCK`), `hyprland` (`HYPRLAND_INSTANCE_SIGNATURE`), `niri` (`NIRI_SOCKET`), `kwin` (`XDG_CURRENT_DESKTOP` lists `KDE`), `gnome` (lists `GNOME`), else `other-wayland` (also pgtk with only `DISPLAY`) |
| `x` | with `WAYLAND_DISPLAY` (Emacs on XWayland): the compositor's adapter, as for pgtk. Otherwise `i3` (`I3SOCK`, or the root window's `I3_SOCKET_PATH`; only checked for existence), else `x11` |
| terminal frame | `tty` |
| none (batch) | `WAYLAND_DISPLAY` stands for pgtk, `DISPLAY` for x; neither: `none` |

`(drgnx-platform-wm &optional FRAME)` returns the name and caches it in the frame parameter `drgnx-platform-wm`;
it never starts a process. A terminal frame counts as a workbench frame elsewhere, so commands check
`display-graphic-p` themselves (the `tty` adapter explains).

**Calls.** `(drgnx-platform-call ARGV :env :timeout :callback)` runs a program without blocking. The callback gets
`ok`, `error` or `timeout` and the output, exactly once, never before the function returns; at the deadline the
process is killed and its later output dropped; a missing program is an `error` ("PROGRAM is not installed"); an
error in the callback is shown with `message`; standard error is read to the end before a failed call is reported;
output is decoded as UTF-8. Deadlines: `drgnx-platform-command-timeout` (2 s, commands),
`drgnx-platform-restore-timeout` (5 s, restoring frames), `drgnx-platform-doctor-timeout` (1 s, the doctor's and
typed commands' `drgnx-platform-call-sync`). `(drgnx-platform-process-env FRAME)` gives the session variables of
the frame as `"K=V"` strings for `:env`; an adapter function calls `(drgnx-platform-ctx-call CTX ARGV CALLBACK)`,
which adds them and the deadline of the operation.

**Monitors** are plists `(:name :make :model :serial :geometry (X Y W H))`. `(drgnx-platform-number-monitors)`
sorts them left to right, then top to bottom and adds `:number` and `:label` ("1 — eDP-1, 1920×1200", "2 — DP-2,
2560×1440, right of 1"). `(drgnx-platform-match-monitor SAVED MONITORS)` finds a saved monitor again: make, model
and serial (all non-empty), else the name, else the geometry. Under pgtk Emacs' monitor `name` is GDK's model
string ("Unknown" under sway), not the compositor's output name, and Emacs lists monitors in no stable order: an
adapter that talks to a compositor matches Emacs' monitors to the compositor's by geometry. For that reason the
monitors drgnx builds from a pgtk frame's `display-monitor-attributes-list` (the gnome adapter's) get the name
`""`: a name is identity only when an adapter that knows the compositor vouches for it (X11 and XWayland report
the real connector names).

**Public operations** (all take a callback; `(:error MESSAGE)` instead of a signal, whatever the adapter does:
a signal in its function, in its reply (a monitor list that cannot be numbered) or in a timer of its own; an adapter
that does not answer within its deadline plus `drgnx-platform-watchdog-margin` (1 s) gets `(:error "timed out")`,
once; a `:detect` function that signals matches nothing): `drgnx-platform-monitors`,
`drgnx-platform-frame-monitor`, `drgnx-platform-move-frame` (a command's path, 2 s), `drgnx-platform-place-frame`
(restoring, 5 s) and `drgnx-platform-can-move` -> `t` or `(REASON . FIX)`, e.g. GNOME: "GNOME does not let apps
move their windows", fix "press Super+Shift+→ or Super+Shift+←".

**Built in:** `x11` and `ns` (frame positions: the move keeps the frame's `fullscreen` value, clears it, sets
`left`/`top` to the target's workarea origin and re-applies it; a negative coordinate is written `(+ N)`, because a
plain negative integer counts from the right or bottom edge. macOS native fullscreen, a Space of its own, is for the
macOS tier to check), `gnome` (explains; the doctor asks Mutter's
`DisplayConfig` for the monitors, within 1 s), `other-wayland` (names the compositor, tells the user to use its
own key), `tty` and `none`. `sway`, `i3`, `hyprland`, `niri` and `kwin` are declared (detection, title, tool,
version command) and have monitor and move functions, described below; `hyprland` and `niri` are marked
`reported`, because their moves are tested on recorded or documented replies and not yet run on the real compositor
with two outputs; `kwin` is `verified` (run headless with two outputs in the window managers' container tier).

**sway and i3** share one implementation over `swaymsg` / `i3-msg` (section "sway and i3" of
`drgnx-platform.el`). Monitors come from `-t get_outputs` (active outputs only; the output `name` is what the move
command takes, and the monitor is matched to Emacs' by geometry). Moving is limited to Emacs' own window while
it has focus: `-t get_tree`, the focused window must be this process (sway: `pid`; i3, whose tree has no pid: the
`window` equal to the frame's `outer-window-id`) and the frame must have focus (`frame-focus-state`), else
`(:error "drgnx moves only its own window while it has focus: ...")`; then `[con_id=N] move container to output
NAME` (i3: `[id=XID]`) and `[…] focus` (the move does not carry focus), plus `fullscreen enable` for a fullscreen
window (`fullscreen enable global` for a global one). An output name with anything but letters, digits and `_.:-`
is double-quoted, so it stays one argument. If the move worked but the follow-up did not, the error says so ("the
window was moved but focus was not restored"); the callback has no success-with-warning. Restoring (`:place`) cannot rely on focus: the frame's `title` parameter is set to `drgnx [placing PID-N]`,
the tree is read at 0.1, 0.3, 0.7, 1.5 and 3 s (then every second) until a window with this pid and title shows
(i3: the window with the frame's X id; no title), the window is moved without taking focus, and the title is
put back whatever happens. All calls of one operation share its deadline (the second call gets what is left), so
the core's watchdog never fires first. Messages: "sway: swaymsg is not installed, so drgnx cannot move windows",
"sway did not answer within 2 s; the window was not moved", or sway's own `error` text.

**Hyprland and niri** (status `reported`: written from the sources and documented replies; niri runs in the window
managers' container tier, nested in a headless sway with its one output, where its output list, a restore's placement,
a command's move to that output and the refusal of an unknown output are checked — the move between two outputs is
not). Monitors come from `hyprctl -j monitors` (mode size divided by the scale, so the geometry is the
logical one Emacs sees) and `niri msg --json outputs`. The monitor a frame is on is Emacs' own answer for both
(`frame-monitor-attributes`, matched by geometry). A command move acts on the focused window only when its pid
is Emacs' and the frame has focus (`frame-focus-state`); otherwise `(:error "drgnx moves only its own window while
it has focus: ...")`. A restore sets the frame's `title` to `drgnx [placing PID-N]`, looks the window up by Emacs'
pid and that title at 0.1, 0.3, 0.7, 1.5 and 3 s, moves it without taking focus and puts the title back in every
case. All calls of one move share the operation's single deadline, so the watchdog margin is not raised. Hyprland
0.56 has two config types and `hyprctl dispatch` differs: a Lua config takes
`hl.dsp.window.move({ window = "address:0x…", monitor = "NAME", follow = … })`; a hyprlang config takes
`focuswindow address:0x…` and `movewindow mon:NAME [silent]` (and the focus is given back after a silent one). The
Lua form is tried first; the answer "Invalid dispatcher" marks a hyprlang instance, remembered per
`HYPRLAND_INSTANCE_SIGNATURE`. niri answers an unknown output with exit 0 and no effect, so the output is looked up
first and an unknown one is an error; the move is `niri msg action move-window-to-monitor --id ID OUTPUT`. (niri warps the
cursor to the target output on a restore too; that cannot be turned off). A hyprlang config splits a dispatcher's
arguments at spaces and commas, so a monitor name with whitespace, `,` or `;` is refused there; if the silent move fails after
the window was focused, the window that had the focus gets it back (best effort, a call of its own).

**KWin** (Plasma 6, status `verified`) has no tool, so the adapter loads a JavaScript file into KWin through its
scripting D-Bus API (`org.kde.KWin` `/Scripting` `loadScript`, then `start`, which runs the loaded scripts not running yet — not `run` on
`/Scripting/Script<id>`: KWin numbers a script by how many are loaded, so after an unload two calls at once can
share an id, and `run` would run the other call's script) and the script
answers with `callDBus` to a `Reply(s)` method Emacs registers for the length of the call. Only Emacs' own
`dbus.el` is used (no `qdbus`), and only `dbus-call-method-asynchronously` with the call's deadline as `:timeout`,
so restore may use it. The method lives under Emacs' unique bus name at an object path of its own per call:
`dbus-register-service` and `dbus-unregister-service` wait for the bus (RequestName, ReleaseName) and a well-known
name would make two calls share a reply. The script, the object and the temporary file (mode 0600) are removed on
success, error and deadline alike. `:monitors` lists `workspace.screens`; `:move` (the command) refuses a frame without focus,
as every adapter does, and moves KWin's active window only if it is Emacs' (by pid) and this very frame (its caption:
the frame's title, else its name), so never another frame of this Emacs; `:place` (restore) sets the frame's `title` to
`drgnx [placing PID-N]` (as sway, Hyprland and niri do), finds Emacs' window by pid and that title (else the only
normal window of that pid) from 0.1 s on, tries again while KWin does not know the title yet, and puts the title back
in every case — so a main window showing the same buffer (the same default title) is never the one moved. KWin places a new window when it first shows
it, which can come after a restore's move: so `:place` checks Emacs' own answer at 0.1, 0.3, 0.7, 1.5 and 3 s and
moves again while the frame is elsewhere, within the restore deadline ("KWin keeps the window on another screen; it
was not placed" when it never gets there). Without D-Bus support or a session bus, `:can-move` says so with a fix. The
monitor a frame is on is Emacs' own answer (`frame-monitor-attributes`, matched to a screen by geometry): Next and
Previous need it, and so does the monitor a restore saves. `:timeout` goes right after the handler in every
`dbus-call-method-asynchronously`: dbus.el sends a `:timeout` placed after the method's arguments as one more
argument, and the call fails ("Wrong type argument: D-Bus, :timeout"). A D-Bus error reply (KWin not running) ends
the call at once with that error; a silent KWin ends it at the deadline. Run against
`kwin_wayland --virtual` with two outputs (`test/live/drgnx-wm-other-test.el`); not run on a full Plasma session.

**Another compositor** (river, Wayfire, labwc, Cosmic, ...): call `drgnx-platform-define-adapter` from your
config. A new name goes before `x11` (so an adapter for an X window manager such as bspwm, awesome or xmonad
wins over plain X) and before the catch-alls `tty`, `other-wayland` and `none`; its `:detect` is tried after the
built-in compositors. Defining an existing name replaces only the keys you give.

```elisp
(drgnx-platform-define-adapter
 'labwc :title "labwc" :status 'reported
 :detect (lambda (env wsys) (and (memq wsys '(pgtk x)) (funcall env "LABWC_PID") t))
 :monitors (lambda (ctx callback)          ; CTX: (:frame :env :wm :timeout)
             (drgnx-platform-ctx-call ctx '("wlr-randr" "--json")
                                      (lambda (status out)
                                        (funcall callback (if (eq status 'ok) (my-parse out) (list :error out))))))
 :move (lambda (ctx monitor callback) ...))  ; CALLBACK: `ok' or (:error MESSAGE)
```

Keys: `:detect` (fn ENV WINDOW-SYSTEM), `:title`, `:tool` (program or nil), `:version` (argv or nil), `:status`
(`verified` = tested against the real thing, `reported` = from documentation), `:monitors` and `:frame-monitor`
(fn CTX CALLBACK), `:move` and `:place` (fn CTX MONITOR CALLBACK; `:place` defaults to `:move`), `:can-move`
(fn CTX -> `t` or `(REASON . FIX)`), `:doctor` (fn ENV -> plist `:monitors`, `:answers`; synchronous).

**The doctor.** `(drgnx-platform-doctor-facts &optional FRAME)` -> `(:wm :title :version :monitors :tool :tool-found
:answers :can-move :status :frame-positions :desktop)`, for `drgnx doctor` and commands only (synchronous). FRAME
defaults to the selected frame (batch: the process environment); a terminal frame or batch is placed by its
environment, and over SSH (`SSH_CONNECTION`, `SSH_TTY`) or without a display `:wm` is `none`. The version comes from
the adapter's `:version` argv, the program's own version flag with no IPC (`sway --version`, `i3 --version`,
`Hyprland --version`, `niri --version`, `kwin_wayland --version`); then at most one read-only query, the adapter's
`:doctor` (sway and i3 `get_outputs`, `hyprctl -j monitors`, `niri msg --json outputs`, Mutter's `DisplayConfig`,
`xrandr --listmonitors` in batch), skipped when the tool is missing or the version call timed out; each within
`drgnx-platform-doctor-timeout`. `x11` has no `:tool`: it moves frames by position, and xrandr only counts monitors.

Tests use `test/fixtures/wm/fake-wm.sh`, linked as `swaymsg`, `i3-msg`, `hyprctl` and `niri` into a temp bin: it logs
its arguments, prints the recorded reply a regexp picks (`DRGNX_FAKE_WM_MAP`) and can sleep or fail.

## Pane kinds (`wb/drgnx-panes.el`)

Every pane (Explorer, agents, terminal, help, …) is one data definition, a kind, made with
`(drgnx-pane-define-kind KIND :title :buffer :placeholder :home :size :view :slot :height :fill :on-show :on-focus :stack)`.
`:home` is `left`, `bottom`, `right` or `editor`. Callers show and find panes by kind and never use the dock, area
or section API directly: `drgnx-pane-show` (`:buffer`, `:select`), `drgnx-pane-hide`, `drgnx-pane-toggle`,
`drgnx-pane-focus`, `drgnx-pane-window`, `drgnx-pane-kind`, `drgnx-pane-kinds`. `drgnx-pane-show` never changes
the selected window unless `:select` is given. `drgnx-pane-backend` (`areas`) says where kinds live; `areas` forwards
a `left` kind to `drgnx-wb-define-section`, a `bottom` or `right` kind to `drgnx-wb-define-tab` (areas `panel` and
`right`), an `editor` kind (its `:buffer` a name) to a `drgnx-wb-place` rule, and `:fill` to
`drgnx-layouts-define-pane`. A backend is an entry in `drgnx-pane--backends` (the functions for `:define`, `:show`,
`:hide`, `:window`, `:focus`, `:resize`, `:move`, `:stack`); the tiled grid registers `grid` there.

**Ownership.** `drgnx-pane-define-kind` records the module whose setup runs as the kind's owner
(`(drgnx-state-kind-owner KIND)`; nil for a kind defined at load, which is core's and stays until restart) and, in a
setup, pushes the undo "pane kind KIND". The undo runs only while KIND is still the definition this module made (two
modules defining one kind may be torn down in either order, `drgnx-module--claim`). It hides KIND on every frame
where it shows, `drgnx-pane-hide :by 'teardown` (the hide notes the size `:by auto`, so a size you chose is kept; a
`left` kind is not hidden, because that would close the whole dock, and its section just goes), then puts the previous
definition back or calls `(drgnx-pane-undefine-kind KIND)`, which removes KIND from `drgnx-pane--kinds` and from
its dock section, area tab or editor place rule (`drgnx-wb-undefine-section`, `-tab`, `drgnx-wb-unplace`). An
area's front tab is intent: the undo reads it first and notes it again `:by teardown` after the tab is gone, so it
names a kind nobody defines for a while (a panel shown meanwhile has that tab's blank placeholder). The module turned
on again defines the kind; a new kind that is in front in an area that shows is shown again `:by teardown`, and a
hidden area shows it at the size you chose at its next show. The leak census reads `drgnx-state--now`,
`drgnx-state--idle`, `drgnx-state--roles` and `drgnx-pane--kinds` (`drgnx-modules-fingerprint-registries`), so a
subscription, role or kind a module leaves behind is named in the per-test diff. Test: `test/unit/wb-state-own-test.el`.

**The write API.** `show`, `hide`, `focus` and `toggle` take `:by`, and three more operations complete them:
`(drgnx-pane-resize KIND PX :horizontal :by)`, `(drgnx-pane-move KIND TARGET ZONE :by)` and
`(drgnx-pane-stack KIND ONTO :by)`. Each runs inside `drgnx-state-with-write` (below): `:by` says who asked —
`user`, `auto`, `layout`, `restore`, `teardown` or `other`; nil is `user` inside a command and `auto` outside.
`resize` gives the dock its width (left kinds), the panel its height (bottom) or the right dock its width (right),
pixelwise as the areas do when they are made, keeps the windows' preserved size at the new one, and notes the size
as `:sizes` intent; it returns the kind's window, or nil when the kind does not show (the size is used at the next
show) or is an editor kind (no size of its own). The `areas` backend has no `:move` or `:stack`: called from Lisp
they signal `user-error` "Moving panes needs the grid" (B7 implements them; their commands are not offered before).
`hide` notes the size the pane had `:by auto`, whoever asked, and `show` of a bottom or right kind notes it as its
area's `:front`. Switching backends and replaying the
defined kinds into the new one is the grid's job (B3), not done here. Test: `test/unit/wb-panes-test.el`.

What the `areas` backend does with the edges:

- `:buffer` is a function, a buffer, or a buffer name (made when missing). A left kind ignores `show :buffer`
  (a section's buffer is its own).
- `hide` does nothing for a kind that is not shown: another view's left kind, or a bottom or right kind that is not
  the area's front tab. Hiding a left kind hides the whole left dock. An editor kind has no hide (so `toggle` of
  one that shows does nothing).
- `drgnx-pane-window` is nil for a non-front tab and for a left kind of another view. An editor kind's window is the
  one showing the last buffer `show` or `focus` put there on that frame (a function `:buffer` or a `show :buffer`
  included).
- `:size` and `:stack` are stored for the grid and not applied; the docks keep their own sizes.
- `:on-show` runs on every `show`, for every home.
- `show` without `:select` never moves focus. A view swap from a window inside the left dock leaves the dock
  first, so focus ends in the editor window rather than in the new dock.
- Redefining a kind with another home takes it out of its old dock; an editor kind's place rule goes when its
  `:buffer` or home changes.

## The UI kit (`drgnx-ui-kit.el`)

What every surface that draws a mark shares. It is in core and requires nothing beyond `subr-x`, so the status bar,
the lists and the notices work without the `ui/face` module.

- `drgnx-face-glyphs` (group `drgnx`; the name is kept so a saved value still applies, and a name a saved value
  lacks comes from the standard table, `drgnx-ui--default-glyphs`) and
  `(drgnx-face-glyph NAME &optional FRAME)`. One glyph per meaning (`close`, `fail`, `stopped`, `dismiss`,
  `unqueue`, `info`, `warn`, `waiting`, …), each `(UNICODE . ASCII)`. Never hard-code a character or a fallback:
  call `drgnx-face-glyph`.
- `(drgnx-ui-ascii-frame-p &optional FRAME)`: a terminal frame whose terminal does not write UTF-8. Tests stub it.
  `drgnx-tty-popups-ascii-p` is an alias.
- Faces `drgnx-status-ok`, `-info`, `-warn`, `-fail` and `-needs-you`. They inherit theme faces only.
- `(drgnx-ui-status SEVERITY &optional TEXT)`: the glyph for `ok`, `info`, `warn`, `fail` or `needs-you` (glyph
  `waiting`), then a space and TEXT, in the status face. The module list and the onboarding steps use it.

## Read and write through drgnx-file

A file drgnx keeps (a config file, a state file, a report) is read and written through `drgnx-file`
(`core/drgnx-file.el`): it takes a lock, writes atomically, backs the file up and refuses to overwrite one it
could not read or one a newer drgnx wrote. Do not call `with-temp-file`, `write-region` or `rename-file`, or read
a file by `insert-file-contents` followed by `read`, in `core/`, `wb/` or `modules/`.
`test/unit/lint-files-test.el` reads those files form by form and fails on such a form (a flagged site is
`(FILE FN WHAT)`; `WHAT` is the function, or `read-site`) unless `test/lint-files-allowed.eld` has a row
`(:file F :fn FN :what WHAT :why "…" :until never)`. Every port of the config-layer plan is done, so every row
is `never` (`drgnx-lint/only-permanent-file-exceptions-remain` fails on any other `:until`), and a row that
matches nothing fails the second test. A row is a site that is not drgnx's own file, and its `:why` starts with
the reason: `"a user's file"`, `"a temporary file"`, `"a directory move"`, `"its own lock protocol"`, `"age
writes it"`, `"a developer tool"` or `"Lisp source"` (a module's source read, never run). A new site is a new row
only when it is one of those; any other file goes through `drgnx-file`.

## Large files: the flag producers check (`core/drgnx-large-file.el`)

A buffer that holds a large file carries the buffer-local flag `drgnx-large-file`: `lean` (the whole file, with the
expensive modes off), `raw` (the whole file, literally) or `chunks` (a part at a time); nil otherwise. It is
permanent-local, so a major-mode change keeps it. The module `editor/large-files` sets it; with the module off it
is never set. The file has no dependencies, so core code and every module require it without loading the module.

A producer (a mode hook, a `find-file-hook` function, a status-bar segment) checks `(drgnx-large-file-p)` and shows
nothing in such a buffer. The predicate is one variable read, safe in redisplay. It takes an optional BUFFER, and
for the current buffer it is also true while `drgnx-large-file--opening` is non-nil: a lean open binds it to `lean`
around the original `find-file-noselect`, so the major mode and its hooks see "large" before the flag is set.
Agents' `fs/read_text_file` serves an open buffer only when it is not a large file and not over
`drgnx-agents-read-max`; otherwise it reads the disk, under the cap.

The producers that check it today: sticky scroll (`drgnx-sticky--maybe`), indent guides (`drgnx-guides--maybe`),
inline blame (`drgnx-blame--maybe`), lang's language server (`drgnx-lang--maybe-eglot`), the gutter's changes
(`extra/hunks` advises `diff-hl--global-turn-on`, `:before-while`, so diff-hl's global mode skips the buffer), the
Outline dock (`drgnx-outline--index`: "This file is too large for an outline", also for a small chunk buffer) and
the status bar (`position` shows `Col N` without the line number, `indent` shows nothing, and the memo's key reads
`tab-width` instead of scanning the first lines). **A new producer that reads or scans the buffer checks the flag
too** and returns early. The callers that visit files bind `drgnx-large-file-open`: Persist (`drgnx-persist--visit`)
and layouts (`drgnx-layouts--put-main`) bind `auto`; Replace's two visits and AI apply-hunk bind `whole`; the agent
edit review sets it to `whole` in its diff buffer, where diff-mode visits the copy. They keep their
`(large-file-warning-threshold nil)`: with the module off, Emacs's own question would come back at start.
A caller that needs the whole file's lines and columns also checks the buffer it is handed: the door reuses an open
buffer as it is, and a chunk buffer holds a part of the file, a raw one undecoded bytes. Replace
(`drgnx-replace--partial`) skips every match of a file open in chunks or raw with a reason, and its Show says so
instead of marking a position. The face module's line numbers (`drgnx-face--numbers-wanted-p`) skip lean and raw
buffers.

A caller that visits a file says what it needs if the file is large by binding `drgnx-large-file-open`: `auto`
(never ask: the remembered answer, else chunks), `whole` (the whole file, lean, never ask) or nil (decided by
context). A buffer whose commands visit files can set it buffer-locally (`setq-local`); the module reads it in the
caller's buffer. A file that only binds it, without requiring `drgnx-large-file`, declares
`(defvar drgnx-large-file-open)` so that a lexical-binding `let` binds it dynamically.

**The door** (`modules/editor/drgnx-large-files.el`) is one named around-advice on `find-file-noselect`. It lets a
visit through unchanged when RAWFILE is given, the name has wildcards, a buffer already visits the file, the file is
missing, a directory or unreadable, or its size on disk is at or below `:ask-above` (one `file-attributes`, one
`drgnx-config-get` of large-files.eld and, for a local file, one `locate-dominating-file`, plus one
`drgnx-config-get` of the project's file when there is one). The header line shows the size the door read (the
dynamically bound `drgnx-large-files--door-size`), without a second stat. Above it, `drgnx-large-files--decide`
picks the mode. Only a command the user gave asks (`read-multiple-choice`, never a dialog box): `this-command` is
set, `drgnx-guard-automatic-p`, `inhibit-interaction` and `non-essential` (a preview from `post-command-hook`) are
nil and the caller bound no `drgnx-large-file-open`.
The answer is remembered for the session. Every other open takes the remembered answer, else chunks (raw without
the chunks module, `drgnx-large-files-chunk-open-function` nil). A second advice, on `server-execute`, binds
`drgnx-large-file-open`: `whole` for a client that waits for its files (`drgnx open --wait`), `auto` for every
other request, the `-e (find-file …)` forms of `drgnx -t` included. Emacs's `server-visit-files` reverts an open
buffer whose file changed with `(revert-buffer t nil)`, which asks; for a lean or raw buffer of one of the request's
files, the same advice (`drgnx-large-files--serve-unasked`) lets an unmodified one revert unasked (its exact name in
`revert-without-query`) and leaves a modified one alone: its record of the file's time is made current while the
request runs, then put back, and the echo area says so. Quit is a `user-error`; the door always returns a buffer. A
raw buffer is reused with RAWFILE t, whatever the file's size now, because without it Emacs itself would ask to
revisit the file normally, a timer's open included.

**Lean** is `drgnx-large-file-mode`. While a lean open runs, `drgnx-large-file--opening` makes the predicate true,
`treesit-max-buffer-size` is below the size (a `*-ts-mode` starts no parser, and its warning is suppressed) and a
`:before-while` advice makes `eglot-ensure` a no-op. A revert runs the major mode again (`after-find-file` calls
`normal-mode`): an around-advice on `normal-mode` binds the same size limit in a lean or raw buffer, so a buffer
that stays large across a revert gets no parser either. The sweep, in `find-file-hook` at depth -90, turns the mode on
for a large file, or for a buffer whose text is above `:ask-above` (a compressed file that expands), never for a
chunk buffer. The mode turns
off every mode of `so-long-minor-modes` that is on (the module adds indent-bars, blame, sticky and diff-hl's margin
mode to that one list), deletes the buffer's tree-sitter parsers and ends eglot's management (a buffer that turns
lean on a revert kept them: auto-revert keeps the modes), then undo and auto-save. A raw visit (`find-file-noselect` with RAWFILE) runs no
`find-file-hook`, so the door runs the sweep itself. A major mode changed by hand (`M-x text-mode`) resets the
minor modes but keeps the flag: `after-change-major-mode-hook`, at depth 90 (after the global modes' turn-on), turns
the mode on again in a lean or raw buffer. An `after-revert-hook` follows the size across `:ask-above`
without a question: a lean buffer at or below it turns lean off and runs `normal-mode` again (only safe local
variables: `drgnx-large-files--never-query` maps every `enable-local-variables` value that may query to `:safe`), a normal one above it turns lean; raw and chunk buffers stay. Before the revert reads a lean or raw
buffer's file, a `before-revert-hook` makes the buffer's record of the file's time current
(`set-visited-file-modtime`): Emacs 31.1 truncates a buffer whose file shrank to a prefix of its text (a file read
without decoding, as raw is) with a change that asks `ask-user-about-supersession-threat` while that record is
stale, and an auto-revert from a timer must not ask. `global-so-long-mode` is on. The
teardown turns lean off in lean and raw buffers but does not re-run their major modes, and says so.

**Chunks** are a second module, `editor/large-files-chunks` (`modules/editor/drgnx-large-files-chunks.el`,
`:packages '(vlf)`), so that `editor/large-files` needs no package and CI tests it without vlf. Its setup sets
`drgnx-large-files-chunk-open-function` to `drgnx-large-files-chunks-open` (`drgnx-module-set`). vlf 1.7.2's `vlf`
selects the buffer it builds, so the function builds the buffer the same way and selects nothing:
`generate-new-buffer`, `set-visited-file-name` (it runs the major mode on the still empty buffer; the flag is set
first, so the producers stay quiet), `set-buffer-modified-p` nil, `vlf-mode`. `vlf-batch-size` is `:chunk-size`,
and vlf's batch-size tuning is off in the buffer, so a chunk always holds that much. vlf runs no `find-file-hook`,
so the lean sweep never sees a chunk buffer: undo stays on, and auto-save is turned off. The buffer-local
`auto-save-visited-mode` is nil (set again after a major-mode change), so the user's `auto-save-visited-mode` timer
never saves a chunk: vlf's save asks when the size changed. A chunk buffer's visited time stays unknown, so it never
auto-reverts and its chunk total stays as it was at the open. `vlf-setup` is never
loaded (its advice asks a question of its own). `drgnx-large-files-chunks-position` gives `(N . TOTAL)`, counted
the way vlf's mode line counts. The module's teardown leaves chunk buffers as they are.

**Switching, the header and the segment.** `drgnx-large-files--switch` refuses a modified buffer (`user-error`),
remembers the new mode, kills the buffer, visits the file again under `(drgnx-large-file-open 'auto)` (the remembered
mode wins) and shows the new buffer in the windows that showed the old one. Large File: Open in Chunks, Open Whole
(lean) and Open Raw call it; each command's `:when` offers it only in a large file's buffer in another mode (chunks
only when they can be built). `drgnx-large-files--header-refresh` builds the header text once, when the mode turns on
or a chunk buffer is built, into the buffer-local `drgnx-large-files--header` (`risky-local-variable`, so its button
properties show) with the size text cached beside it. The header line shows that variable: as
`drgnx-chrome-header-tail` after the breadcrumb when the workbench's chrome is on, else as the buffer's
`header-line-format`. A button's `local-map` runs `drgnx-large-files--header-click` on `[header-line mouse-1]`.
A major-mode change resets both, and `after-change-major-mode-hook` builds them again. The status-bar segment
`large-file` reads only the flag, the cached size and the chunk position. It is defined by
`(eval-after-load 'drgnx-statusbar (drgnx-modules-with-owner …))` and put before `position` with
`drgnx-module-set`. `drgnx-statusbar-define-segment` records no undo yet (teardown Task 23), so the module's teardown
removes the segment from `drgnx-statusbar--segments` by hand, and the header from chunk buffers.

## The workbench state store (`wb/drgnx-state.el`, `core/drgnx-frame-kind.el`)

One observed answer for "which windows, panes and frames are there". The store keeps one record per workbench
frame, a cache of Emacs's window tree. It has one writer, the observer, which only looks: it never splits, deletes,
resizes or selects a window, and never sets a window or frame parameter. Readers ask the store instead of walking
windows or keeping their own copy (an MRU window, a visibility flag, a frame kind, "the edges I saw last").

**What a frame is.** `(drgnx-state-frame-kind FRAME)` is the one classifier: `child` (it has a parent: posframes,
quick help's card, Emacs 31's terminal child frames), `initial` (the initial terminal's frame: a daemon's, or a GUI
Emacs's before its first frame; in batch Emacs that frame is `tty`, so batch tests have a workbench frame),
`other` (a minibuffer-only frame), `gui`, else `tty`; nil for a dead frame. `drgnx-state-workbench-frame-p` is
non-nil for `gui` and `tty`; only those frames get a record. The frame roles (`wb/drgnx-frames.el`) ask it:
`drgnx-frames--workbench-p` is that and `frame-visible-p`, `drgnx-frames--candidate-p` the same with a role other than
`editor`; `drgnx-session--windows` lists the visible workbench frames; `drgnx-first-gui-frame-hook` runs when a frame's
kind is `gui` (the `core/` files require only `drgnx-frame-kind`); `drgnx-session-open-folder` raises the
graphical window when the selected frame is `gui` or `initial`. A minibuffer-only frame is `other`, so it no longer
counts as a window for `drgnx-session--windows`. The writers of `drgnx-frame-role`
(`drgnx-frames-mark-main`, `drgnx-frames--deleted`, `drgnx-frames--first-gui`) and of `drgnx-monitor`
(`drgnx-monitors--write`) call `drgnx-state-sync` on the frame after writing.
No other library compares a terminal's name with `"initial_terminal"` or asks `frame-parent` to tell a child
frame: the terminal modules (layout, frames, popups, fallback layer), the face and the start page ask the
classifier (`(eq (drgnx-state-frame-kind frame) 'tty)`, `'child`). `drgnx-lint/one-frame-classifier` fails on a
second place; its list of libraries not yet moved can only shrink.

**A frame's record** holds its kind, its `drgnx-frame-role` (copied), whether it is visible (`t`, `icon`, nil), its
size (text columns and lines, pixel width and height), its `drgnx-monitor` (copied), its selected window, its MRU
editor window, its windows and the pane kinds that show. **A window's record** holds the window, its role, the pane
kind it shows (or nil), its buffer, its pixel edges (left, top, width, height) and whether it is dedicated. Windows
are in `window-list` order from the frame's first window. The records are internal; use the reads below.

**Roles come from one table.** `(drgnx-state-define-role ROLE :chrome C)` defines a non-editor role, the value of
the `drgnx-role` window parameter; `C` is what the chrome draws for it: `dock`, `area`, `lane` or nil
(`drgnx-state-role-chrome`). Built in (core, defined at load): `dock` (dock), `panel` and `right` (area), `popup`
(lane). A module defines its own roles in its setup: the definition records its undo ("state role ROLE"), which
puts the previous definition back or removes the role, only while the role is still the one defined there; two
modules may be torn down in either order (`drgnx-module--claim`). `drgnx-state-undefine-role` removes one. A
window's role, in this order: a `drgnx-popup` parameter (a popup lane, also the panel a popup borrowed) → `popup`;
a `drgnx-role` in the table → that role; a side window → `side` (a package's own); else `editor`; the minibuffer has
none. A `drgnx-role` nobody defined counts as an editor window — define the role.

**Pane kinds.** A dock window shows its `drgnx-section`; an area window (a role with chrome `area`, named like the
area) shows its front tab (the frame's `drgnx-wb-areas`, as `drgnx-wb-area-tab`); an editor window shows its
`drgnx-layouts-pane`, or the editor-home kind whose last buffer on that frame it shows (`drgnx-pane--last`). A
popup lane shows no kind (the panel's tab is hidden while a popup borrows it).

**The MRU editor, per frame:** the frame's selected window if it is an editor window; else the frame's previous
editor while it is still an editor window there; else the editor window with the highest `window-use-time`; else
nil. `window-use-time` alone is not trusted: a package's `select-window` without NORECORD bumps a window the user
never chose. `(drgnx-state-use-editor WINDOW :by BY)` makes WINDOW its frame's editor without selecting it (the
dock's "open in the editor" target). While a non-editor window (the dock) is selected, the choice holds as long as
WINDOW lives. While an editor window is selected, it holds only until the record is next taken anew: any change to
the frame's windows (a selection, a buffer, a split, a resize) makes the selected editor window the editor again.
A window that is not an editor → nil; so is a window whose frame has no record yet while an observation runs.

**Reads**, each nil for a dead window or frame, all from the records: `drgnx-state-editor-window`,
`drgnx-state-selected-window` (FRAME optional, default the selected frame), `drgnx-state-frames` (oldest first,
optionally of one kind), `drgnx-state-main-frame` (the oldest recorded frame whose role is `main`;
`drgnx-frames-mark-main` stays the writer), `drgnx-state-windows FRAME ROLE`, `drgnx-state-window-role` (a window
not observed yet is classified live), `drgnx-state-edges`, `drgnx-state-pane-window KIND FRAME`,
`drgnx-state-pane-shown-p KIND FRAME` (shown on a visible frame), `drgnx-state-shown-kinds` (whatever the frame's
visibility), `drgnx-state-frame-size` (`(:cols :lines :width :height)`).

**When the records are taken.** `drgnx-state--observe FRAME` first compares the record with the live frame in place
— size, visibility, selected window and, per window in order, identity, buffer, role, edges, dedication and pane
kind (a dock's section, an editor's layouts pane or editor kind; an area's front tab only through its buffer) —
allocating nothing (about 3.5 µs on a 7-window frame, byte-compiled). A frame it has a record of is not classified
again (only its parent and its life can change, and `terminal-name` makes a string). Only on a difference does it
take the record anew. A frame that has just become the selected frame, with its windows unchanged, keeps its record
and emits `selected-changed` (Events, below). Only the mode's hooks see a frame switch: a sync or a write may run
inside `with-selected-frame` (a restore per frame), and the frame it selects for a moment is not the user's. Every record replaced, by an observation or by
`drgnx-state-use-editor`, goes through one internal function, `drgnx-state--put`; records are never changed in
place. While it runs, a change made meanwhile
waits for the next observation. `drgnx-state-mode` (global; `core/workbench` turns
it on) runs it from five named functions: the default value of `window-state-change-functions` (any change from
any source, before the frame is drawn), `post-command-hook` at depth −90 (the selected frame, even when redisplay
is skipped), `pre-command-hook` (only notes that a command runs), `after-make-frame-functions` and
`delete-frame-functions` (the record goes). On, it observes every live workbench frame, oldest first; off, the
records go. Records live in a table weak on the frame. Observation binds `inhibit-interaction`; an error lands in
`drgnx-signal-errors` and is never raised.

**`drgnx-state-sync`.** `(drgnx-state-sync &optional FRAME)` observes FRAME now and returns a copy of its record
(nil for a frame that is not a workbench frame); the lists inside it are the store's and read-only. Call it when code changes windows and reads the store in the same breath (a
timer that shows a pane and then asks for its window), and after setting `drgnx-frame-role` or `drgnx-monitor`:
setting a frame parameter is no window change, and only `drgnx-state-sync` compares those two — `frame-parameter`
copies every parameter of the frame to read one of ours, too much for every command. Batch Emacs has no
redisplay: batch tests call `drgnx-state-sync`. Writes run inside `(drgnx-state-with-write (FRAME BY) BODY…)`:
`drgnx-state--writing` is `(:by BY)` while BODY runs, and FRAME is observed at the end. BY defaults to
`drgnx-state-default-by`: `user` inside a command, `auto` outside.

**Events.** `(drgnx-state-subscribe EVENT FN :lane LANE)` calls FN with a plist when EVENT happens;
`drgnx-state-unsubscribe` stops it. FN is a named function: a lambda is refused, so it can be removed and named in
reports. Each (EVENT FN) pair is subscribed once; subscribing it on the other lane moves it. Called from a module's
setup, the subscription records its undo, "state subscription EVENT FN". The undo removes FN only if it was not
subscribed before, and only while it is still on that lane; two modules may be torn down in either order
(`drgnx-module--claim`). The events are diffed where a record is replaced (`drgnx-state--put`, after the new record
is stored), so an observation and `drgnx-state-use-editor` both emit them. An event nobody subscribes to is not
computed. In one observation they go out in this order; `frame-removed` comes on its own:

| Event | When | Data |
|---|---|---|
| `frame-added` | a `gui` or `tty` frame is first recorded | `:frame :kind` |
| `frame-kind` | its kind, `drgnx-frame-role` or `drgnx-monitor` changed (seen at `drgnx-state-sync`) | `:frame :old :new`, each `(:kind :role :monitor)` |
| `frame-resized` | its text columns or lines, or its pixel size, changed | `:frame :old :new`, each `(:cols :lines :width :height)` |
| `windows-changed` | a window came or went, or shows another buffer or role | `:frame :windows` |
| `groups-changed` | editor windows came or went | `:frame :added :removed` |
| `pane-hidden` | a pane kind stopped showing in a window: its window went, an area's front tab changed, a dock shows another section | `:frame :kind :window :cause :by` |
| `pane-shown` | a pane kind started showing in a window (a kind moved to a new window is hidden, then shown) | `:frame :kind :window :cause :by` |
| `pane-resized` | the edges of a pane's window or an editor window changed | `:frame :window :kind :old :new :cause :by` (edges `(LEFT TOP WIDTH HEIGHT)`) |
| `selected-changed` | the frame's selected window changed, or the frame became the selected frame | `:frame :window :old-window :old-frame` |
| `editor-changed` | the frame's MRU editor window, or its buffer, changed (`C-x o` between two windows of one buffer too) | `:frame :window :buffer :old-window :old-buffer` |
| `frame-removed` | the frame's record went (`delete-frame-functions`, or it is no workbench frame any more); the frame is still live | `:frame` |

A frame's first record emits `frame-added`, then everything it shows as new: `windows-changed`, `groups-changed`,
`pane-shown`, `selected-changed`, `editor-changed`.

**`:cause` and `:by`** say who changed a pane. `write` with `:by` from the write (`user`, `auto`, `layout`,
`restore`, `teardown`, `other`; `drgnx-state-with-write`). `user` with `:by user`: a command in
`drgnx-state-user-resize-commands` (a user option), or any step of a mouse drag on a divider (Emacs 30+ runs the steps as commands of a transient
map, `this-command` is a closure, and `track-mouse` is `dragging`). Else `other` with `:by` nil: Emacs fitting a popup, the minibuffer growing, the
window manager resizing the frame, a package.

**Two lanes.** `now` (`:lane 'now`) calls FN inside the observation, possibly during redisplay, before the frame
is drawn: for cheap reactions only. It may update a mode line, set a window parameter (chrome), start or cancel a
timer, or choose the editor (`drgnx-state-use-editor`, which emits its own `editor-changed`). It never moves a
window, scans buffers or calls a process. A change it makes waits for the next observation, and the jank guard
counts a window it moves. `idle` (the default) queues the call: one per FN, event, frame and kind (the data's
`:kind`), with the last data. The bus's idle flush (`drgnx-signal--flush`, `drgnx-signal-delay`, 0.05 s) makes
them, oldest first, after observing the selected frame; the store has no timer of its own. The handler reads the
records then. Every call binds `inhibit-interaction`, so a subscriber that prompts gets an error.
An error is recorded in `drgnx-signal-errors` as `"EVENT FN: message"` (newest first, at most 20), never raised.
Subscribers of one event run in subscription order.

The Work cockpit's panes are such consumers ([cockpit.md](cockpit.md)): `pane-shown` and `pane-hidden` on `now` start
and cancel each pane's check (and an agent's edits' file watches), so a hidden pane keeps no timer; `pane-resized` on
`idle` re-fits the graph and the feed. A kind whose buffers swap in one window (an agent's edits, What happened) hears
`windows-changed` too: one buffer replacing another in a pane's window is no pane event. Whether a buffer shows is
`drgnx-cockpit-shown-p`: a window the store recorded on a visible frame shows it.

**The fixture** (`test/fixtures/state-fixture.el`): `(drgnx-test-with-state BODY…)` runs BODY with a fresh store
and bus and the store's hooks off. It saves every bound variable listed in `drgnx-state-test--variables` (the
store's tables, its subscribers and idle queue, `drgnx-signal--subscribers`, `--state`, `--posted`, `--timer`,
`--editor`, `--switched`, `drgnx-signal-errors`) and restores them with `set` afterwards, never `let`; timers are
cancelled on the way in and out. A batch test delivers the idle lane by calling `drgnx-signal--flush` (or only
`drgnx-state--deliver-idle`). A task that adds store or bus state adds its variable there. `(drgnx-test-use-editor
WINDOW)` makes WINDOW the MRU editor through `drgnx-state-use-editor`. Tests never set bus internals by hand. Tests: `test/unit/wb-state-test.el`, `test/unit/wb-state-events-test.el`
(one per event, the lanes, `:cause`); the terminal tier's `test/tty/state-test.el` (a split made by a timer is seen
with no command run; two clients: per-frame editors, a resized terminal); the GUI tier's `test/ui/state-ui-test.el`
(with `now` subscribers on, splits, `C-x o`, a popup and a frame resize leave no jank-guard entry from the store; a
minibuffer-only frame is no workbench frame).

**The status bar** (`modules/ui/drgnx-statusbar.el`) is a `now` subscriber of `editor-changed`
(`drgnx-statusbar--editor-changed`: one `(force-mode-line-update t)`), so the full and the compact bar trade places
on the first redraw, `C-x o` between two windows of one buffer included, in every frame. `drgnx-statusbar--mru-editor-p`
is `(eq W (drgnx-state-editor-window (window-frame W)))` and `drgnx-statusbar-source-window` falls back to
`drgnx-state-editor-window`; the bar keeps no window of its own and posts nothing to the bus. Its post-command check
compares the buffer, point, change tick and mark only. Its git read stays on the bus's idle `editor-changed`. Its
debounced refresh is the layer timer `statusbar-refresh` (`drgnx-timer-soon`, owner `:core`, cancelled when the mode
turns off). Tests: `drgnx-statusbar/` in `test/unit/mod-statusbar-test.el`; `drgnx-statusbar-ui/` in
`test/ui/statusbar-state-ui-test.el`.

### Intent (`wb/drgnx-state-intent.el`)

The snapshot says what is on screen; **intent** says what was asked, and by whom, per frame: the size a pane comes
back at, an area's front tab, the sidebar's view. It is readable data only (symbols and numbers). Until the grid
(B3) it has no storage of its own: the accessors read and write today's frame parameters, so nothing is stored
twice and the saved workbench (`workbench.eld`) does not change.

| `(drgnx-state-intent FRAME KEY SUBKEY)` | Answer | Home until B3 |
|---|---|---|
| `:sizes` `left` | `(:px N :by BY)` | `drgnx-wb-dock-px` |
| `:sizes` `bottom` (also `panel`) | `(:px N :by BY)` | `drgnx-wb-panel-px` |
| `:sizes` `right` | `(:px N :by BY)` | `drgnx-wb-right-px` |
| `:front` AREA | the tab in front | the area's `:tab` in `drgnx-wb-areas` |
| `:view` | the sidebar's view, also one no module defines now | `drgnx-wb-view` |
| `:layout`, `:previous`, `:zen-return` | read-only until B10 | `drgnx-layouts-current`, `-previous`, `-zen-return` |
| `:places`, `:arrangement` | nil until the grid | — |

Without SUBKEY, `:sizes` and `:front` answer an alist of every home or area. FRAME nil is the selected frame.

`(drgnx-state-note-intent FRAME KEY SUBKEY VALUE :by BY)` writes VALUE to the home (a size as N or `(:px N)`) and
records BY in the frame parameter `drgnx-intent-by`, an alist `((KEY . SUBKEY) . BY)`, newest first, at most 64
entries (the oldest goes); entries of kinds or areas no module defines now are kept. BY nil is the running write's,
else `drgnx-state-default-by`. It returns non-nil when it wrote. **A size you chose wins:** a `user` size is replaced
only by `user` or `restore` — not by `auto` (a hidden panel that a popup squeezed), `layout`, `teardown` or `other`.
A `restore` replaces anything and counts as `user` afterwards (a size restored after a restart is still yours). The
front tab and the view are what shows until the grid, so every write of them lands and only records who asked.
`:layout` and the others answer nil (not written). The writers today: `drgnx-pane-resize`; hiding the dock
(`drgnx-wb-hide-sidebar`, a view swap), the panel or the right dock (`drgnx-wb-area-hide`) notes the size `:by auto`;
`drgnx-wb-show-view` notes `:view`; a pane kind shown in an area notes `:front`; a layout notes its sizes `:by
layout`. B3 folds the homes and `drgnx-intent-by` into one frame parameter, `drgnx-intent`.

**A size you set by hand is intent.** `drgnx-state-intent--user-resized` is an `idle` subscriber of `pane-resized`,
subscribed in `core/workbench`'s setup (so teardown unsubscribes it). For an event with `:cause user` (a divider drag,
`enlarge-window`; `drgnx-state-user-resize-commands`) on a window of role `dock`, `panel` or `right`, and a change along
the dimension that home has (width for the docks, height for the panel), it notes `:sizes HOME (:px N) :by user` and
marks `window-preserve-size` on that window — a window parameter, nothing moves — so a later frame resize (the window
manager) does not take the size back. A write (`:cause write`, the event's `:by` says who), a popup squeezing the panel
and every other resize are not the user's and note nothing. Until B3 only sizes are protected. B3 carries this into
the grid's R4. Tests: `test/unit/wb-state-intent-test.el`; `test/ui/state-intent-ui-test.el` (a dragged dock keeps its
width when the frame resizes).

## Tests

Batch: `test/unit/core-*-test.el`. The batch runner (`harness/run-ert.el`) gives the suite a temp HOME and drgnx
dirs, and unsets the provider keys (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`OPENAI_API_KEY`): no test reaches a paid model. In a session: `test/live/drgnx-boot-test.el` boots `config=drgnx` and checks
the registry, the guard (a `y-or-n-p` from a timer signals), the palette (`C-S-p`), the key sheet (F1) and the
module report. Scenarios run against drgnx with `bin/drgnx test --scenario`; the workbench ones skip until M3.

## Testing: time, waits and processes

A test never waits in real time for a timer, and a machine under load cannot fail a correctness test. Load the clock
fixture the way the other fixtures are loaded: `(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)`.
Its API and examples are in [harness.md](harness.md), "Virtual time"; this is what it guarantees.

**The clock.** `drgnx-test-with-clock` runs its body with `timer-list` and `timer-idle-list` bound to nil, so every
timer the body starts, whoever starts it, lands in lists of its own. `float-time` and `current-time` without an argument
return the real time at entry plus the virtual seconds so far (timestamps stay plausible); with an argument they are
Emacs's own. `drgnx-test-clock-now` is the virtual seconds so far (0.0 at entry).

**What moves time.** Only these:

- `drgnx-test-advance` runs the wall timers due within its argument in due order, repeats included, and
  `drgnx-test-idle` is one idle pause (`current-idle-time` is the pause so far, `input-pending-p` turns t at
  `:input-at` and the pause ends there);
- `sleep-for` and `sit-for` move it by their argument and run the timers that come due; process output is then looked
  at once with a zero wait. `sit-for` returns nil only when simulated input is pending, and simulated input ends it
  early;
- a timed `accept-process-output` moves it by the real time it waited (`drgnx-test-real-time`), then the due timers run.

A polling loop with a `float-time` deadline therefore ends at once under virtual time; a test that polls a real
process keeps a realistic deadline. More than `drgnx-test-clock-max-runs` (10000) timer runs in one
`drgnx-test-advance` is an error (a timer that re-arms with no delay).

**The guard.** A wall timer is stamped by Emacs from the real clock. While the fixture is active a `:before` advice on
`timer--activate` moves such a timer to the virtual due time plus `drgnx-test-clock-horizon` (10^6 s), so C's timer
check never finds it ripe during a real wait: a real wait fires no virtual timer. A timer is due at virtual *v* + *d*
when it was made at *v* with delay *d*, also after an advance. A re-armed repeat is already in that era and is left
alone. Give timers delays, not absolute times computed from `float-time`: such a time reads as a real stamp.

**The end.** A timer still pending in the body's own lists when the body ends fails the test
(`timers still pending at the end of drgnx-test-with-clock`), named by `(KEY OWNER KIND)` for the timer layer's
timers (`drgnx-timer-pending`), then by function; `:allow-pending t` cancels them quietly. A layer timer started before
the body (its timer is on the real list) is not the body's and fails nothing. `drgnx-timer-reset` runs either way.
Emacs's own `undo-auto--boundary-timer` is dropped first: it is never the body's. Nesting is an error.

**The timer layer.** When `drgnx-timer--now` is defined at entry, the layer's three seams (`drgnx-timer--now`,
`drgnx-timer--idle-time`, `drgnx-timer--input-pending-p`) follow the same clock, pause and input. Require the timer
layer before the fixture: loading it inside the body is an error (the fixture could not unbind its seams on exit).

**What stays real.** `time-since`, `(time-subtract nil …)` and `format-time-string` with no time read the real clock;
a test of code that uses them uses real time.

**Native trampolines.** Advising a primitive compiles a native trampoline for it. The fixture advises
`float-time`, `current-time`, `current-idle-time`, `input-pending-p`, `sleep-for` and `accept-process-output` (and
`sit-for`); the batch runner sends the trampolines to the run's eln directory (`DRGNX_TEST_ELN_DIR`), never to `~`
(the test `drgnx-test-clock/trampolines-land-in-the-runs-eln-dir` checks it).

### Waits (`test/fixtures/wait-fixture.el`)

A test that waits for real asynchronous work (a process, its filter or sentinel) calls
`(drgnx-test-wait PRED &key (secs 30) what)` and nothing else: no hand-rolled `accept-process-output` loops. It
returns PRED's first non-nil value, polling with `(accept-process-output nil 0.02)` against real time.

- **The deadline is generous.** It is SECS times `(drgnx-uitest-settle-scale)` (the load per core, or
  `DRGNX_UITEST_SETTLE_SCALE`) and only bounds a failure; a pass costs what the work costs. A correctness test
  therefore never fails because the machine is loaded.
- **A timeout says what was live.** It signals `ert-test-failed` with
  `(:waited-for WHAT :secs S :last-value V :processes ((NAME STATUS)…) :timers (FUNCTION…))`, so the failure names what
  the test waited for, PRED's last value, the live processes and the pending timers. Pass `:what`.
- **Wait on a done flag.** Have the sentinel (or filter) set `(process-put p :done t)` and wait for
  `(process-get p :done)`. `process-live-p` turns nil before the sentinel has run, so a wait on it races the
  sentinel (M3b-19). `drgnx-lint/test-waits-read-a-done-flag-not-process-live-p` fails for any `drgnx-test-wait`
  under `test/` whose PRED mentions `process-live-p`.
- **Inside the clock fixture** (`drgnx-test-with-clock`) it works unchanged: the deadline is read through
  `drgnx-test-real-time`, and each timed `accept-process-output` advances virtual time by the real wait.

Load it as the other fixtures are loaded: `(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)`.

### Test ports

A test never picks a port by chance. The mock LLM (`test/fixtures/mock-llm.el`) is started with
`(drgnx-ai-test-mock-llm nil SCRIPT [LOG])`: it listens on a port the system picks and reports it on one line
(`MOCK-LLM-PORT N`), which the call reads before it returns; the process's `:port` property is that port, and the
config is written with it. The readiness check is that report, so another program listening on a port cannot pass for
the mock. A number instead of `nil` asks for that port and errors when it is taken. A "dead provider" that must refuse
connections uses `(drgnx-test-free-port)`: a port a listener of this Emacs just bound and released. The mock CDP and
MCP servers listen on `:service t` and return their port the same way.

### Measuring in a unit test (`test/fixtures/measure-fixture.el`)

A test that guards a cost asserts what load does not move. Load the fixture as the others are loaded:
`(load (expand-file-name "test/fixtures/measure-fixture" drgnx-dir) nil t)`.

- **Allocation first.** `(drgnx-test-alloc BODY…)` is what BODY allocates: one unmeasured run, then the least of three
  measured runs of the `memory-use-counts` delta summed over its seven kinds (conses, floats, vector cells, symbols,
  string characters, intervals, strings), less the 7 conses the reading itself makes, so an empty BODY gives 0. The
  same code on the same Emacs gives the same number however loaded the machine is. A bound is
  `ceil(1.25 × max(measured on 30.2, measured on 31.1))`, both numbers in the commit message; "stays linear" or "does
  not scan the whole file" is a ratio between two sizes (A-45: the sticky segment at line 9000 allocates at most
  1.25 × the one at line 1000; a walk over the lines between allocates 45231 against 5231).
- **Compile what you measure.** Tests load code from source when it is newer than its `.elc`, and interpreted code
  conses for its own bookkeeping. `(drgnx-test-compile PREFIX…)` byte-compiles in place every interpreted function
  whose name starts with one of the prefix strings, so the number is what users run and does not depend on which
  test compiled what before. BODY itself runs as written: its own `let`s count when the test file is loaded from source.
- **CPU when allocation cannot say it.** `(drgnx-test-cpu-ms (&key (n 50)) BODY…)` is the median `current-cpu-time` of
  N runs, in ms (with N even, the mean of the middle two). CPU time moves less with load than wall clock, but it
  moves: keep 3× headroom over the host's median.
- **Wall clock only with `:timing`.** A test that must time itself on the wall clock is tagged `:timing`; `check`
  runs those alone. A budget on a wait (an onboarding step's seconds) runs on the clock fixture instead and reads
  `drgnx-test-clock-now`: the step's timed waits move virtual time by the real time they wait, and a provider's delay is
  a virtual timer, so a loaded machine cannot fail it (FLAKY-2, `drgnx-ai-onboard/the-role-tests-run-side-by-side`).

### Scripted processes (`test/fixtures/scripted-process.el`)

A race between a child's output, its exit and Emacs's reads (class C) shows up only under load, so a test forces the
ordering instead of hoping for it. `(drgnx-test-scripted-process NAME &key buffer filter sentinel)` starts a `sh` child
that does only what the test tells it, through a FIFO in a fresh directory under `temporary-file-directory` (never
`~`; the child removes it when it exits). Its stdin is the process's own, so `process-send-string` and
`process-send-eof` reach it as they would a real child.

- `(drgnx-test-proc-emit P TEXT)`: the child writes TEXT to its stdout, after everything it was told before. The call
  returns at once.
- `(drgnx-test-proc-exit P CODE &key before-read)`: the child exits with CODE. With `:before-read t` the call returns
  only once Emacs has recorded the exit, and it has read none of P's output and run no filter, sentinel or timer (it
  blocks in `call-process`). Output and exit are then all pending when Emacs next reads, and `process-live-p` is
  already nil while the sentinel has not run (M3b-19).
- Telling an exited child anything more is an error.

What Emacs guarantees, and what the tests (`drgnx-test-proc/`, each ordering 100 times out of 100) force:

- **Output, then exit, before Emacs reads:** the filter gets all the output, and the sentinel runs after it.
- **No filter call after the sentinel:** before it runs a sentinel, Emacs reads the output left and closes the pipe.
  The sentinel can still run *inside* a filter call: a filter that waits (a nested `accept-process-output`, `sit-for`,
  a synchronous request) lets the last output and the sentinel run before the call goes on. Code after a wait in a
  filter must expect the process to be finished.
- **`process-send-eof` after the exit** signals `Process NAME not running: finished` (A-44), before the sentinel and
  after it: a runner that sends EOF to a child that may already have exited handles that error.

Concurrency tests use explicit barriers (A-23) — a scripted step, a done flag, a marker the child writes — and never
sleeps: a sleep only makes the race rarer.

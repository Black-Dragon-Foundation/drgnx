# Extensions

How the Extensions view gets its list. The hub's side (`extensions/*`) is in [the hub](hub.md#extensions).

## The catalog file

`drgnx extensions refresh [--progress FILE]` writes `<cache>/extensions/catalog.json`. It is a batch command
(`core/drgnx-extensions-refresh.el`) that a hub job runs; the editor never starts it itself, because it reaches the
network.

- **It changes nothing you have installed.** The archives' contents land in `<cache>/extensions/pkg/`, never in the
  packages directory. What is installed is read from the lock (`drgnx-pkg-read-lock`), and the update plan is
  `drgnx-pkg--plan` in upgrade mode over descs made from the lock, with nothing installed. A `drgnx sync` that swaps
  `elpa/` while a refresh runs changes nothing the refresh reads.
- **It fails whole.** An archive that does not answer, or whose signature does not verify, fails the refresh (exit 1)
  and the old `catalog.json` stays: the file is written as a `.tmp` file and renamed.
- **Signatures.** URL archives sign their contents unless they are MELPA's or listed in `packages.eld`'s
  `:unsigned-archives`; a directory archive does not. The refresh runs under the archive settings sync uses.
- **Download counts** come from MELPA's `download_counts.json`, kept at `<cache>/extensions/download_counts.json`; the
  job fetches it when MELPA is an archive, and a failed fetch is a message, not a failed refresh.
- **Progress.** With `--progress FILE` the job appends one line per step (`fetching the archives`, `reading the
  packages`, `writing the catalog`).

`drgnx extensions fetch-readme ARCHIVE NAME` caches one package's readme at
`<cache>/extensions/readme/ARCHIVE/NAME-readme.txt` (a directory archive's file is copied, a URL archive's downloaded).
A name with a separator or a leading dot is refused.

### Format (`version` 1)

```json
{"version": 1, "written": 1730851200.0, "emacs": "31.1",
 "archives": [{"name": "gnu", "url": "https://elpa.gnu.org/packages/", "signed": true}],
 "packages": [{"name": "magit", "summary": "…", "keywords": ["git"], "maintainer": "…", "url": "…",
               "commit": "9be04d7…", "revdesc": "…", "kind": "tar",
               "versions": [{"archive": "melpa", "version": "20261104.815", "reqs": [["dash", "2.19"]]}],
               "candidate": {"archive": "melpa", "version": "20261104.815"},
               "update": {"from": "4.1", "to": "4.2", "from_commit": "…", "to_commit": "…"},
               "held": false, "incompat": false, "downloads": 4212345}],
 "builtins": [{"name": "eglot", "version": "1.17", "summary": "…"}],
 "skipped": [{"archive": "melpa", "name": "odd", "why": "its summary is not text"}]}
```

- `candidate` is what `package.el` would install, priorities applied.
- `update` is present when the update plan takes the package (`from` is the lock's version). `held` is true when an
  archive has a version newer than the lock's that the plan does not take (a pin, or a requirement no archive has).
  `incompat` is true when the candidate needs a newer Emacs than the one that ran the refresh. `reqs` leave Emacs out.
- `downloads` is absent when MELPA's counts are not there or do not name the package.
- `skipped` names every entry the job could not use: a summary that is not text, or text that is not valid. The rest of
  the archive is kept.
- A reader ignores keys it does not know and refuses a `version` other than 1.

## Live activation

`modules/tools/drgnx-extensions-live.el` keeps a running session working while an Extensions job changes `elpa/`
(user guide: [When a restart is needed](../guide/extensions.md#when-a-restart-is-needed)). The Extensions module's
setup calls `drgnx-extensions-live-setup`, which puts `drgnx-extensions-live-plan` on
`drgnx-extensions-jobs-plan-functions`, the done handler on `drgnx-extensions-jobs-done-functions` and the in-use
file's removal on `kill-emacs-hook`.

- **The repoint rule.** For each package directory D the plan's `replaces` or `removes` names (and, from
  `(drgnx-extensions-live-before NAMES)`, each directory of NAMES), every `load-path` entry equal to `elpa/D` or under
  it is replaced, one `setcar` on its cell, by its counterpart under `generations/N/elpa/D` — N the plan's generation
  (the current one for `-before`) — **only when that counterpart exists**. A package with no copy (a stock install, a
  sync with a missing package) is marked "restart drgnx" at once and its entries stay.
- **The claim.** Whenever the session points into a generation it writes `<state>/elpa-in-use/PID.eld`
  (`(:pid P :start S :generations (N…))`, `drgnx-file-write`); with none, and at `kill-emacs`, the file goes.
  Snapshot rotation keeps those generations (`drgnx-pkg-generations-in-use`).
- **After the job** (`(drgnx-extensions-live-after RESULT)`, RESULT the done object). Not `:ok t`: the entries the
  job moved go back under `elpa/` and its marks go. `:ok t`: the session settles on `elpa/`, recomputing every mark —
  a package at elpa's version points back there; a changed package is loaded when `load-history` holds a file of its
  directory (autoloads and `-pkg` files do not count), and it keeps its old version together with every changed
  package linked to it by requirements, either way ("Restart to use 1.1 (1.0 is running)", or "Restart to finish
  removing" for a removed one); the others leave `load-path` and `package-activated-list`, and every package of
  `elpa/` new to the session is activated with `package-activate` from fresh descriptors, unless it needs a kept one
  (marked instead); a directory in use that is gone is repointed into the newest generation holding it, else marked
  "files of dash 2.19 are gone: restart drgnx". Then `drgnx-modules-retry-waiting`.
- **A removed package's modes go off.** The plan step reads the modes index entry of each package `removes` names
  (`drgnx-extensions-index-read`, or its autoloads file when the index lacks it) **before** the swap, which rewrites
  the index without it. After a job that went well, for each such package `elpa/` has no version of: its index
  entries leave `auto-mode-alist`, `interpreter-mode-alist` and the magic alists; a buffer in one of its major modes
  runs `normal-mode` (`enable-local-variables :safe`, `inhibit-interaction`) and turns back on the other packages'
  buffer minor modes it had on; its buffer minor modes are called with -1 in every buffer.
- `(drgnx-extensions-live-restart-pending)` → `((NAME . TEXT)…)`: a cache read, for the view's rows.
- Nothing prompts, waits or signals (an error is one notice), and nothing writes `elpa/`, the lock or the quickstart
  file. Turning the module off removes the hooks; the in-use file then stays until the next snapshot sweeps it, once
  the session is gone, so a generation it still loads from is never deleted under it.

## In one project

User guide: [In one project](../guide/extensions.md#in-one-project).

- **The modes index.** `core/drgnx-extensions-index.el` writes `<cache>/extensions/modes.eld` after every sync,
  upgrade or rollback that worked (`drgnx-pkg--index-modes` is on `drgnx-pkg-after-change-functions`): for each
  installed package `(PKG :auto ((REGEXP . MODE)…) :interpreter (…) :magic (…) :minor (MODE…) :scope SCOPE)`, from
  its `PKG-autoloads.el` read as data (never evaluated). `:auto`, `:interpreter` and `:magic` are the constant
  entries of its `add-to-list`s to the mode alists; `:minor` its autoloaded `-mode`s whose signature is `(fn
  &optional ARG)` and that have no variable of their own there (a global minor mode has one). SCOPE is `global` when
  the file holds, anywhere, an `add-hook`, `advice-add`, `add-function`, a global minor mode, a binding in a global
  keymap (`global-set-key`, `keymap-global-set`, `define-key global-map …`) or a theme; else `narrow` when it adds an
  entry or a minor mode; else `none`. `drgnx-extensions-index-counts` gives `(:narrow N :global N :none N)`.
- **The setting.** `drgnx-packages-off` (`:scope 'project :workspace 'data :agents 'never`), declared in
  `modules/tools/drgnx-extensions-project.el`. `(drgnx-extensions-project-set PKG ROOT OFF)` writes it into ROOT's
  **private** workspace file (`drgnx-settings-editors-commit`, tab `workspace`), refuses a package that is not
  `narrow` (a `user-error`: "On in every project: it changes Emacs as a whole"), and runs `normal-mode` in ROOT's
  open file buffers. `(drgnx-extensions-project-off-p PKG ROOT)`, `(drgnx-extensions-project-describe PKG ROOT)` (the
  row's words) and `drgnx-extensions-project-toggle` are for the view.
- **While a package is off somewhere** (your value, your private workspace files, the shared files drgnx read;
  `drgnx-extensions-project-refresh`, again on `drgnx-settings-changed-functions`): a named `:around` advice on
  `major-mode-remap` acts only in a buffer with `buffer-file-name` asked for a mode of a package off in its project
  (the root its private workspace file names, else the folder of the nearest `.drgnx/settings.el`; the value read
  by root with `drgnx-setting-for-root`, since the buffer's project values are not applied yet when its mode is
  chosen): it answers for the mode `set-auto-mode` would choose with those packages' modes taken out of
  `interpreter-mode-alist`, `magic-mode-alist`, `auto-mode-alist` and `magic-fallback-mode-alist`, in that order,
  else `fundamental-mode`. A named function on `after-change-major-mode-hook` (depth 100) turns their buffer minor
  modes off in such a buffer. With nothing off, neither is installed. The Extensions module's setup calls
  `drgnx-extensions-project-setup`, its teardown `drgnx-extensions-project-teardown` (both go).
- `drgnx doctor`'s `package-modes-off` check lists the open file buffers where such a mode is still on
  (`drgnx-extensions-project-misses`).

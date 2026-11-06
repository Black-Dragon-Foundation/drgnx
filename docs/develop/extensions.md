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
- `(drgnx-extensions-live-restart-pending)` → `((NAME . TEXT)…)`: a cache read, for the view's rows.
- Nothing prompts, waits or signals (an error is one message), and nothing writes `elpa/`, the lock or the quickstart
  file. Turning the module off removes the hooks; the in-use file then stays until the next snapshot sweeps it, once
  the session is gone, so a generation it still loads from is never deleted under it.

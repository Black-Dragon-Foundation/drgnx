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
- **Signatures.** The refresh runs under the archive settings a sync uses (`drgnx-pkg-with-archive-settings`), so it
  checks what a sync checks: every archive signs its contents except MELPA and stable MELPA (by name or by URL),
  directory archives and those listed in `packages.eld`'s `:unsigned-archives` (`drgnx-pkg-unsigned-archives`). The
  catalog's `signed` says which.
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

## Jobs

Every install, update, removal, rollback and refresh the view asks for is a hub job
(`modules/tools/drgnx-extensions-jobs.el`): named `Extensions: …`, `:machine "local" :local-only t`, a time box of
7200 s, its command `bin/drgnx …`. The editor never waits on one; C-g never stops one, Cancel does. The Extensions
module's setup calls `drgnx-extensions-jobs-setup` and its teardown `drgnx-extensions-jobs-teardown`.

- **Clicks.** `(drgnx-extensions-jobs-queue '(:add magit :latest "4.2"))` writes the click to `pending.eld`
  ([the queue](../guide/packages.md#the-queue)) and returns its ticket; `:latest`, the version the page showed, stays in
  the editor. The click joins the queue run that is **waiting** — a `drgnx sync --pending --wait` job that has started
  but whose first step this session has not seen — or starts one. That run takes the whole queue once it holds the
  sync lock and names the tickets in its `start` step. At the first step seen of each run and at each run's end the
  layer compares the queue with what the runs took, and a ticket still there (clicked after the run took the queue)
  gets one new run, so no click is stranded. When another drgnx holds `pending.eld` the click is not queued: the
  row says "busy, try again". `drgnx-extensions-jobs-cancel` takes a ticket still queued out of the file, or stops a
  job by its id.
- **Other jobs.** `(drgnx-extensions-jobs-run KIND ARGS… :callback FN)`: `upgrade` NAMES (`:stage`, `:staged`),
  `upgrade-all`, `rollback` N, `refresh`, `fetch-readme` ARCHIVE NAME, `plugin-install` PATH (`:replace`),
  `plugin-remove` NAME; FN gets the job's id.
- **Progress.** Each job's progress file is `<state>/extensions/progress/TOKEN.json`, TOKEN made by the editor
  before the job starts (so a job is followed before the hub names it); `TOKEN.json.plan.json` is its swap plan. One
  file-notify watch on the directory while the module runs; reads are coalesced by `drgnx-timer-soon` (at most four a
  second, the last change always read). Without a file-notify backend the rows show the elapsed time only, and the end
  still comes from the hub's `exec-done`. A job's files are deleted once its result is read, and files older than a
  week at setup. Syncs run from the command line or by onboarding write no progress file.
- **Plans.** A new `*.plan.json` runs `drgnx-extensions-jobs-plan-functions` once per `seq`, for every Extensions job's
  file whichever session started it: the state directory is shared, so every running drgnx repoints before the swap.
- **Rows.** `(drgnx-extensions-jobs-state ID)`, ID a package or a ticket, is a cache read: `(:status queued|busy|done|failed|stopped
  :step :pkg :i :n :since :error :warnings :job :tickets)`. `drgnx-extensions-jobs-changed-functions` get the ids that
  changed; `drgnx-extensions-jobs-done-functions` get each ended job's id and result.
- **Results**, from the summary of the job's end: the reason is the last `drgnx:` line; a `MISSING` line of a name no
  archive has reads "not in any archive you use: gnu, nongnu, melpa"; `WARNING … does not byte-compile` lines are
  "partly compiled: a.el, b.el", a warning and not a failure; "installed 4.3, not the 4.2 the page showed" when the
  plan's package directory has another version than the page showed. `drgnx-extensions-jobs-retry` queues the failed
  clicks of a job again.
- **At setup,** after the hub's first `exec/list` answer (`drgnx-exec-listed-hook`): Extensions jobs an earlier session
  started are followed again (a finished one's result is read), and a ticket in `pending.eld` that no waiting run will
  take gets one.

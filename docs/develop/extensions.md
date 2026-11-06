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

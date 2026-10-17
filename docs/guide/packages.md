# Packages

drgnx installs packages in one place only: `drgnx sync`, a command you run. Emacs never installs anything on
its own, and neither does the daemon at startup, a timer or a module. Installed packages are pinned in a lock,
every downloaded file is kept in a cache, and each sync leaves a **generation** you can go back to at once.

```
drgnx sync                  install what drgnx needs (from the archives, the cache and the lock)
drgnx sync --offline        only the lock and the cache — no network
drgnx sync --seed DIR       first copy the packages of another Emacs (e.g. ~/.config/emacs/elpa), then sync
drgnx upgrade               the newest versions; if they break, the previous generation comes back
drgnx rollback [N]          the packages of generation N (default: the one before the current one)
drgnx generations           the generations kept (five)
drgnx lock                  what the lock pins
drgnx safe                  Emacs with drgnx's core only: no modules, no packages
drgnx bisect [-- CMD…]      find the module that breaks something
drgnx service-unit [DIR]    the systemd user unit for a drgnx daemon (printed, or written to DIR)
```

## What gets installed

The **manifest** is:

- the `:packages` of every enabled module (Preferences: Modules — a module you turn off stops asking for its
  packages);
- `:packages` in `~/.config/drgnx/packages.eld`:

  ```elisp
  (:packages (rainbow-delimiters treesit-auto)
   :archives (("gnu" . "https://elpa.gnu.org/packages/")
              ("melpa" . "https://melpa.org/packages/")))
  ```

  `:archives` is optional (default: GNU ELPA, NonGNU ELPA, MELPA); a local directory works as an archive;
  `:archives ()` means none (sync then works from the cache only);
- what `use-package … :ensure` asked for in a session, or an external module's files (gryphn) would have
  installed. In drgnx `:ensure` installs nothing: it records the package use-package would have installed
  (`:ensure t` the package itself, `:ensure other` that one, `:ensure nil` none) in
  `~/.local/state/drgnx/packages-wanted.eld` and says so in `*Messages*`; the next `drgnx sync` installs it and
  forgets the want.

`drgnx sync` resolves each package of the manifest with its dependencies (package.el — one that no archive has
is reported and does not stop the others), downloads what is missing into `~/.cache/drgnx/packages/` (an HTTP
error is never saved; hash and signature are checked, where the archive signs, before a file enters the cache),
byte-compiles, compiles to native code ahead of time (when your Emacs has native compilation; into
`~/.local/share/drgnx/eln-cache/`, for the files at their final path), and writes the activation file sessions load
at startup. A download or an install that fails stops the sync with nothing changed, and a file that did not
install is removed from the cache. A download or a lock write that stops half way (an error, `C-g`) leaves no
partial file; what a killed sync left (`*.part` in the cache, `.drgnx.lock.eld.tmp-*`) the next sync removes. A file that does not compile (byte or native) is not a failure: the package is
installed, runs that file less compiled, and the sync prints a `WARNING` line naming the package and the file. Sync never removes a package: one installed by hand stays and is locked too.

### Packages from Git

A package no archive has comes from its repository, pinned to a commit. Name it in `packages.eld`:

```elisp
(:git ((eglot-booster :url "https://github.com/jdtsmith/eglot-booster" :rev "main")
       (my-tool :url "https://codeberg.org/me/my-tool" :rev "v1.2" :lisp-dir "lisp")))
```

`:rev` is a branch, a tag or a commit (default: the repository's default branch); `:lisp-dir`, where the package's
files are when not at the top. drgnx's own modules name a few such packages themselves (`drgnx-pkg-git-sources`;
`packages.eld` comes first). `drgnx sync` clones the repository into `~/.cache/drgnx/packages/git/NAME/` (never asking
for a password: a private repository needs credentials git already has without asking), takes the commit, installs
the package from `NAME.el`'s headers (its `Version:`, or `0.0.0.DATE` of the commit when it has none) and its
`Package-Requires` from the archives. The lock records the commit; a sync keeps it until `drgnx upgrade` takes the
newest commit of `:rev`, and `drgnx sync --offline` installs it from the cached clone.

## The lock

`~/.config/drgnx/drgnx.lock.eld` pins every installed package: version, archive, file and its sha256 (commit it
with your configuration) — or, for a package from Git, its URL, `:rev` and the commit. A sync installs the locked version — from the cache when the archive moved on, replacing
another installed version — and refuses a file whose hash differs from the lock (a changed file, or a tampered
cache; the file is dropped from the cache): nothing changes then. A locked version that no archive and no cache has
any more, or one older than another package needs, is reported (with what needs it), the packages that do not
depend on it are installed, the command exits non-zero and the lock stays as it was — `drgnx upgrade` moves the
lock to the archives' versions. An unreadable lock is an error, never silently replaced.

`drgnx sync --offline` installs exactly the lock from the cache: on a new machine, copy the cache and the lock and
sync without network. A manifest package the lock does not have is reported ("sync online once").

## Generations, rollback, upgrade

Packages live at one fixed path, `~/.local/share/drgnx/elpa` (`$DRGNX_DATA_DIR`). A sync installs into a copy and
swaps it in with two renames only when everything arrived, so an interrupted sync leaves the old directory as it
was (a crash between the two renames is repaired by the next sync). Each successful sync snapshots the directory
and the lock as a generation (`~/.local/share/drgnx/generations/N`, reflink copies where the file system has them —
on a file system without them, every sync copies the packages twice; five kept).

`drgnx rollback` copies a generation back into the same path, so natively compiled files stay valid — nothing
is recompiled. `drgnx upgrade` snapshots the packages first, takes every package to the archive's newest version,
then runs a smoke test (a fresh Emacs that activates drgnx's packages and loads each package of the manifest that
has a file of its name); if the upgrade or the smoke test fails, the snapshot and its lock come back and the output
says why.

A running drgnx keeps the packages it loaded: **restart it** after a sync, upgrade or rollback (the command says
so). One writer at a time: a sync, upgrade or rollback refuses while another runs; a lock left by one that died is
taken over. The lock (`~/.local/share/drgnx/sync.lock`) names its process by pid and start time, so a pid reused
after a reboot does not hold it, and of two commands taking over the same stale lock only one gets it.

## When something breaks

- `drgnx safe` starts Emacs with drgnx's core only — no packages, no modules — to tell drgnx problems from module
  or package problems.
- `drgnx bisect` finds the module: it turns half of the enabled modules off — external ones (`:external` in
  `modules.eld`, e.g. gryphn) included, as `external/NAME` — (in a copy of your configuration;
  your files are untouched), starts drgnx and asks whether the problem showed, and halves again — about log2(N)
  rounds. `drgnx bisect -- CMD ARGS…` runs CMD instead of asking (a non-zero exit means "the problem showed";
  `DRGNX_CONFIG_DIR` points at the copy).
- `drgnx doctor` reports packages the manifest needs that are not installed, a missing or unreadable lock, and the
  generations kept.

## Running drgnx as a daemon

`drgnx service-unit` prints a systemd user unit (`Type=notify`, `emacs --fg-daemon=drgnx
--init-directory=<checkout>/init`); `drgnx service-unit DIR` writes `DIR/drgnx.service`. drgnx never installs or
enables it. The unit runs the Emacs that ran the command — `$DRGNX_EMACS`, default `emacs` — by its full path
(quoted for systemd, so paths with spaces work). Choose another one when you write the unit, e.g.
`DRGNX_EMACS=emacs-pgtk drgnx service-unit DIR` on Fedora where `emacs` may be another build. To run it next to your current Emacs daemon:

```sh
drgnx sync --seed ~/.config/emacs/elpa         # your packages, copied; then whatever drgnx adds
drgnx service-unit ~/.config/systemd/user
systemctl --user daemon-reload
systemctl --user start drgnx                     # emacsclient -s drgnx -c
```

Give the unit the same `Environment=`/`PATH` as your current daemon's unit if it has some. Switching for good is
a systemd drop-in on your old daemon's unit; going back is deleting the drop-in.

## For module authors

A module names its packages (`:packages '(magit)`) and does not install them: the module waits ("needs magit" in
Preferences: Modules) until `drgnx sync` has run. A lint fails on `use-package :ensure`/`:vc`, `package-install`,
`package-vc-install` or `package-refresh-contents` in `modules/`.

## Tests

`test/unit/pkg-test.el` runs everything against package archives that are local directories in temp dirs (never
the network): sync with dependencies, offline sync into an empty directory, a wrong hash, a missing locked
version, concurrent syncs, seeding, rollback byte for byte, a broken upgrade restored, the guard, use-package
`:ensure`, bisect, the CLI, the doctor and safe mode. HTTP downloads run against a loopback server in the test
Emacs itself (a 200 is saved byte for byte; a 404 saves nothing). `test/unit/pkg-git-test.el`: packages from local Git
repositories — the commit and dependencies, the lock holding the commit until upgrade, offline from the cached clone,
a missing `:rev`, no version header, a module's package with drgnx's Git source.

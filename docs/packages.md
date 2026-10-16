# Packages

drgnx installs packages in one place only: `drgnx sync`, a command you run. Emacs never installs anything on
its own, and neither does the daemon at startup, a timer or a module. Installed packages are pinned in a lock,
every downloaded file is kept in a cache, and each sync leaves a **generation** you can go back to at once.

```
drgnx sync                  install what drgnx needs (from the archives, the cache and the lock)
drgnx sync --offline        only the lock and the cache — no network
drgnx sync --seed DIR       first copy the packages of another Emacs (e.g. ~/.config/emacs/elpa), then sync
drgnx upgrade               the newest versions; if they break, the previous generation comes back
drgnx rollback [N]          the packages of generation N (default: the one before the newest)
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
- what `use-package … :ensure t` asked for in a session. In drgnx `:ensure` installs nothing: it records the
  package (`~/.local/state/drgnx/packages-wanted.eld`) and says so in `*Messages*`; the next `drgnx sync`
  installs it.

`drgnx sync` resolves the manifest with its dependencies (package.el), downloads what is missing into
`~/.cache/drgnx/packages/` (signatures checked where the archive signs), byte-compiles, compiles to native code
ahead of time (when your Emacs has native compilation; into `~/.local/share/drgnx/eln-cache/`), and writes the
activation file sessions load at startup. Sync never removes a package: one installed by hand stays and is
locked too.

## The lock

`~/.config/drgnx/drgnx.lock.eld` pins every installed package: version, archive, file and its sha256 (commit it
with your configuration). A sync installs the locked version — from the cache when the archive moved on — and
refuses a file whose hash differs from the lock (a changed file, or a tampered cache): nothing changes then. A
locked version that no archive and no cache has any more is reported, the rest is installed, the command exits
non-zero and the lock stays as it was (`drgnx upgrade` moves to the archive's version). An unreadable lock is an
error, never silently replaced.

`drgnx sync --offline` installs exactly the lock from the cache: on a new machine, copy the cache and the lock and
sync without network.

## Generations, rollback, upgrade

Packages live at one fixed path, `~/.local/share/drgnx/elpa` (`$DRGNX_DATA_DIR`). A sync installs into a copy and
swaps it in with two renames only when everything arrived, so an interrupted sync leaves the old directory as it
was, and a running session never sees half of one. Each successful sync snapshots the directory and the lock as a
generation (`~/.local/share/drgnx/generations/N`, reflink copies where the file system has them; five kept).

`drgnx rollback` copies a generation back into the same path, so natively compiled files stay valid — nothing
is recompiled. `drgnx upgrade` takes every package to the archive's newest version, then runs a smoke test (a
fresh Emacs that activates the packages and loads each one of the manifest); if it fails, the previous generation
and its lock come back and the output says why.

One sync at a time: a second `drgnx sync` (or upgrade) refuses while one runs; a lock left by a sync that died is
taken over.

## When something breaks

- `drgnx safe` starts Emacs with drgnx's core only — no packages, no modules — to tell drgnx problems from module
  or package problems.
- `drgnx bisect` finds the module: it turns half of the enabled modules off (in a copy of your configuration;
  your files are untouched), starts drgnx and asks whether the problem showed, and halves again — about log2(N)
  rounds. `drgnx bisect -- CMD ARGS…` runs CMD instead of asking (a non-zero exit means "the problem showed";
  `DRGNX_CONFIG_DIR` points at the copy).
- `drgnx doctor` reports packages the manifest needs that are not installed, a missing or unreadable lock, and the
  generations kept.

## Running drgnx as a daemon

`drgnx service-unit` prints a systemd user unit (`Type=notify`, `emacs --fg-daemon=drgnx
--init-directory=<checkout>/init`); `drgnx service-unit DIR` writes `DIR/drgnx.service`. drgnx never installs or
enables it. To run it next to your current Emacs daemon:

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
`:ensure`, bisect, the CLI, the doctor and safe mode.

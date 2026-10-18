# Packages

drgnx installs packages in one place only: `drgnx sync`, a command you run. Emacs never installs anything on
its own, and neither does the daemon at startup, a timer, a module or a hook that happens to run inside one of
your commands (opening a file, say): `package-install`, `package-refresh-contents` and the like are refused from those (with an error saying
so) and work when you run them yourself: `M-x package-install`, `M-x list-packages`, an Install button, `M-:`. Installed packages are pinned in a lock,
every downloaded file is kept in a cache, and each sync leaves a **generation** you can go back to at once.

```
drgnx sync                  install what drgnx needs (from the archives, the cache and the lock)
drgnx sync --offline        only the lock and the cache — no network
drgnx sync --seed DIR       first copy the packages of another Emacs (e.g. ~/.config/emacs/elpa), then sync
drgnx sync --prune          also remove the packages the manifest no longer needs (listed; rollback restores them)
drgnx upgrade               the newest versions; if they break, the previous generation comes back
drgnx rollback [N]          the packages of generation N (default: the one before the current one)
drgnx generations           the generations kept (five)
drgnx lock                  what the lock pins (version, and the archive or, for Git, the commit)
drgnx lock --ship           (maintainers) write the known-good lock drgnx ships from yours
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
  `:archives ()` means none (sync then works from the cache only); `:archive-priorities` (e.g.
  `(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1))`, package.el's `package-archive-priorities`) makes a package come
  from the highest priority archive that has it, even when another has a newer version (without it, the newest
  version wins — usually MELPA's build of the latest commit);
- what `use-package … :ensure` asked for in a session, or an external module's files (gryphn) would have
  installed. In drgnx `:ensure` installs nothing: it records the package use-package would have installed
  (`:ensure t` the package itself, `:ensure other` that one, `:ensure nil` none) in
  `~/.local/state/drgnx/packages-wanted.eld` and says so in `*Messages*`; the next `drgnx sync` installs it. The want stays
  in that file (so the package stays in the manifest, and `drgnx sync --prune` keeps it); delete the name from the file
  when you no longer want it.

`drgnx sync` resolves each package of the manifest with its dependencies (package.el — one that no archive has
is reported and does not stop the others), downloads what is missing into `~/.cache/drgnx/packages/` (an HTTP
error is never saved; hash and signature are checked, where the archive signs, before a file enters the cache),
byte-compiles, compiles to native code ahead of time (when your Emacs has native compilation; into
`~/.local/share/drgnx/eln-cache/`, for the files at their final path), and writes the activation file sessions load
at startup. A download or an install that fails stops the sync with nothing changed, and a file that did not
install is removed from the cache. A download or a lock write that stops half way (an error, `C-g`) leaves no
partial file; what a killed sync left (`*.part` in the cache, `.drgnx.lock.eld.tmp-*`) the next sync removes. A file that does not compile (byte or native) is not a failure: the package is
installed, runs that file less compiled, and the sync prints a `WARNING` line naming the package and the file (compat's per-version files, `compat-29.el` and the like, load only on an older Emacs and are not compiled to native code, so they never warn). A plain sync never removes a package: one that left the manifest (a module turned off) or was installed by hand stays and is locked too. `drgnx sync --prune` removes them: every installed package the manifest does not name and no package of the manifest requires — hand-installed ones included. It is never automatic, it lists what it removed (`pruned: …`), it removes nothing while a package is missing, and it first keeps a generation of the state before, so `drgnx rollback` brings them back.

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

The packages of the manifest that the lock has install at their locked versions, together with what their lock
entries require — not with what the archives' newest versions would need — so a lock installs as the set it was
made from even when an archive has moved on (MELPA builds every commit). A locked package that is there
only because another package requires it, and that a built-in one already satisfies at the version required (e.g.
`compat` on a newer Emacs), is not installed, as package.el would not (a package the manifest itself names is
installed as locked); a requirement the lock does not have is resolved from the archives, except one on a Git-sourced
package, which installs from its source. Packages install after the packages they
require. Each archive entry also records its download's size (`:size`), which onboarding uses to say how much it
would download.

`drgnx sync --offline` installs exactly the lock from the cache: on a new machine, copy the cache and the lock and
sync without network. A manifest package the lock does not have is reported ("sync online once").

### The lock drgnx ships (your first sync)

drgnx comes with a known-good lock, `etc/drgnx.lock.eld` in its checkout: the packages of **every** module (all
presets) with what they need, at versions tested together — GNU ELPA and NonGNU ELPA releases where those archives
have the package, MELPA's build otherwise (forge and its dependencies, apheleia), and eglot-booster from Git at a
commit. When you have no lock yet, `drgnx sync` first copies it to `~/.config/drgnx/drgnx.lock.eld` (marked
`:from-shipped t`) and then installs those versions (hashes checked as always) — only the packages of the modules
you have on. A sync with `--seed DIR` does not: the packages it copies are your choice, and the lock records them.
Deleting your lock on purpose gets you the shipped set again, the same way.

**The first sync's pins are soft.** The archives serve only their current release of a package in a form
package.el installs (GNU ELPA and NonGNU ELPA keep older ones as `.tar.lz` only, MELPA none at all — its builds move
with every commit). While the lock still carries the `:from-shipped` mark, a shipped version no archive and no
cache has any more — or one older than another package needs — is not a missing package: sync drops that pin, takes
the current version from the same archive (another one's only when that archive no longer has the package), plans
again, and prints a warning for each, e.g. `WARNING fa: shipped 1.0 no longer served; installed 1.1`. The rest stays
at the shipped versions, the command exits 0, and the lock records what was installed. The first successful write
of the lock drops the mark; from then on your lock is the one that counts — it always wins over the shipped one, a
locked version nobody has is reported as above (never replaced), a later sync keeps your versions, and `drgnx
upgrade` moves them on.

The first sync needs the network; offline (`--offline`, with the archives' files in the cache) it installs what the
cache has and names the packages it could not get — a Git package always needs one online sync for its clone — and
the next sync online completes it. An interrupted first sync leaves the packages directory as it was (the copied
lock stays, still marked; a re-run uses it). drgnx's maintainers refresh the shipped lock so a first sync falls back
rarely:

```sh
# a full-ai sync in empty temporary drgnx directories: releases first, MELPA only for what they lack
export DRGNX_CONFIG_DIR=$(mktemp -d) DRGNX_DATA_DIR=$(mktemp -d) XDG_CACHE_HOME=$(mktemp -d) XDG_STATE_HOME=$(mktemp -d)
cat > "$DRGNX_CONFIG_DIR/packages.eld" <<'END'
(:archives (("gnu" . "https://elpa.gnu.org/packages/") ("nongnu" . "https://elpa.nongnu.org/nongnu/")
            ("melpa" . "https://melpa.org/packages/"))
 :archive-priorities (("gnu" . 3) ("nongnu" . 2) ("melpa" . 1)))
END
drgnx onboard --non-interactive --preset full-ai --step look-and-keys
drgnx sync
drgnx lock --ship          # writes etc/drgnx.lock.eld; commit it
```

`drgnx lock --ship` writes the entries of every module's packages (on or off) and of what they need from the
current lock — never your own packages — and refuses, writing nothing, when the lock lacks one of them (it names
them: turn every module on and sync first), or when one of them has no hash (an archive entry without `:sha256`,
e.g. a seeded package) or no commit (a Git entry): a new user would install it unchecked. A package that a built-in
one satisfies on the maintainer's Emacs is not installed there, so it is in neither the maintainer's lock nor the
shipped one: a user whose Emacs is older gets it from the archive, unpinned (the newest version, as any package
beyond the lock).

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
says why. Without `:archive-priorities`, the newest version wins: a first `drgnx upgrade` after the shipped lock moves
packages it took from GNU or NonGNU ELPA releases (magit, …) to MELPA's latest builds where MELPA has them — set
priorities ([above](#what-gets-installed)) to stay on releases.

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
- `drgnx doctor` reports packages the manifest needs that are not installed (not those your Emacs ships, such as
  `eglot`), a missing or unreadable lock, and the generations kept.

## Running drgnx as a daemon

`drgnx service-unit` prints a systemd user unit (`Type=notify`, `emacs --fg-daemon=drgnx
--init-directory=<checkout>/init`); `drgnx service-unit DIR` writes `DIR/drgnx.service`. drgnx never installs or
enables it. A daemon that fails is restarted after 2 seconds, at most 3 times a minute, so a second drgnx holding the server name does not loop. The unit runs the Emacs that ran the command — `$DRGNX_EMACS`, default `emacs` — by its full path
(quoted for systemd, so paths with spaces work). Choose another one when you write the unit, e.g.
`DRGNX_EMACS=emacs-pgtk drgnx service-unit DIR` on Fedora where `emacs` may be another build. To run it next to your current Emacs daemon:

```sh
drgnx sync --seed ~/.config/emacs/elpa         # your packages, copied; then whatever drgnx adds
drgnx service-unit ~/.config/systemd/user
systemctl --user daemon-reload
systemctl --user start drgnx                     # emacsclient -s drgnx -c
```

Once the unit is enabled, `drgnx open` and `drgnx PATH` start it when drgnx is not running ([opening.md](opening.md)).
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
`:ensure`, bisect, the CLI, the doctor and safe mode — and the shipped lock: a first sync installing exactly its
versions (where the archives' newest would need others), a user lock winning over it, `lock --ship` covering every
module and refusing entries without a hash or commit, an interrupted first sync leaving nothing half done, a shipped
pin nobody serves falling back (with a warning, its dependents installed) while a user's own lock still reports it,
`--seed` keeping the seeded versions, a requirement beyond the lock installed and a locked package a built-in
satisfies left out (each test has its own shipped lock in a temp dir, never the checkout's). HTTP downloads run against a loopback server in the test
Emacs itself (a 200 is saved byte for byte; a 404 saves nothing). `test/unit/pkg-git-test.el`: packages from local Git
repositories — the commit and dependencies, the lock holding the commit until upgrade, offline from the cached clone,
a missing `:rev`, no version header, a module's package with drgnx's Git source, an offline first sync naming the Git
package it could not get and installing the rest.

# Extensions

One list for everything that extends drgnx: packages, plugins, the editor's modules and Emacs's built-ins. Open it
with `C-S-x` (VS Code keys), `SPC x` (Vim keys) or **Open Extensions** in the palette and the View menu.

The editor never installs anything by itself and never waits for the network. A click on Install, Update or
Uninstall is queued and run by a background job; the row shows how it goes (`◎ native 14/37 · 12s`) and what came of
it. `C-g` never stops a job; **Cancel** (`k`, Vim `x`) does.

## The list

Rows are grouped in sections: **Installed**, **Updates**, **Recommended** (what this project's
`drgnx-extensions-recommended` names), **Plugins**, **Built-in** and **Generations**. Each row has the kind's mark
(`⬡` package, `◆` plugin, `▣` module), the name, the version, a chip for its state, and on a second line the summary,
the archive it comes from and how far you can trust that (signed, unsigned archive, local, Git commit, hash approved).
`drgnx-extensions-list-density` set to `dense` keeps one line a row. The next 200 rows load as you near the end.

Chips: *update to X*, *held* (a newer version exists that the update plan does not take), *missing: no archive you use
has it*, *failed*, *queued*, *stopped*, *partly compiled: a.el, b.el* (the package works; those files did not
byte-compile), *restart to use* (an update that a running session cannot load yet). When updates wait for a restart the
header says so and has a **Restart drgnx** button.

## Searching

`/` opens the search; the list follows what you type. Words that start with `@` filter:

| Word | Keeps |
|---|---|
| `@installed` `@updates` `@builtin` `@plugins` | those rows |
| `@enabled` `@disabled` | modules that are on or off |
| `@unsigned` | packages from an archive that does not sign |
| `@archive:melpa` `@kind:module` `@keyword:vc` | by archive, kind or keyword |
| `@recommended` `@this-project` | what this project recommends, or decides about |
| `@failed` `@restart` | rows whose job failed, or that wait for a restart |
| `@generations` | the generations of your packages |
| `@sort:name` `downloads` `updated` `installed` | the order |

A word after `@` that is none of these shows as a quiet chip, *not a filter*; it never stops the search.

## Keys

| Command | VS Code | Emacs | Vim |
|---|---|---|---|
| Open Extensions | `C-S-x` | palette, View menu | `SPC x` |
| Search | `/` | `/` | `/` |
| Details | `RET` | `RET` | `RET`, `l` |
| Install | `i` | `i` | `i` |
| Update, Update all | `u`, `U` | `u`, `U` | `u`, `U` |
| Uninstall | `d` | `d` | `d d` |
| Turn on or off in this project | `p` | `p` | `p` |
| Refresh | `g` | `g` | `g r` |
| Cancel | `k` | `k` | `x` |
| Show log | `L` | `L` | `L` |

Uninstall asks nothing: a rollback (see Generations) brings the package back. A package something else still needs is
refused and the row says why.

## A page for each extension

`RET` on a row opens its page in a preview tab that the next page replaces; `RET` again on the same row keeps it. The
page has the name, the versions, where it comes from and how far to trust that, the maintainer, the address, **Why**
it is here (*you (Extensions) · needed by forge · config.el:31 (:ensure)*), and, for code, the line every extension
carries: *Runs inside Emacs as you: it can read your files and reach the network.* Then the buttons for what you can do,
and the tabs **Readme**, **Changes**, **Settings (N)**, **Dependencies** and **Files**.

The readme of an installed package is its own text: the `;;; Commentary:` of its main file and the README files in its
folder, shown as plain text. No mode runs on it, no `-*- eval: … -*-` line is obeyed, nothing is coloured. A package
you have not installed shows the readme its archive publishes: the first time its page opens, a background job fetches
it ("Fetching the readme…"), and it is shown as the same inert text (see [Where it comes from](#where-it-comes-from)).
Its **Files** tab lists the files of its archive once it was downloaded. Changes shows the installed commit, a
compare link for GitHub, GitLab, Codeberg and sourcehut repositories, `git log` since this version for a Git package,
and its NEWS or CHANGELOG file. A module's page shows what the module is for, its packages, flags, stage and how long
it took to start, with a button that turns it on or off through its setting. The **⋯** button (and **More About
Extension** in the palette) offers another version (the versions still in the cache), copying the name, opening the
repository, the package's settings and the job's log.

Settings has a **Preferences: Settings** side: under Extensions it lists the packages you asked for, read-only, from the
lock, and each package's settings group says *magit 4.1 · Extensions* with a link back to this list.

## Where it comes from

Every package runs inside Emacs as you, so its page says how far its source can be trusted. GNU ELPA and NonGNU ELPA
sign their packages, and drgnx checks the signature: *signed*. MELPA and stable MELPA do not sign (*unsigned archive*);
a directory archive is *local*; a Git package is pinned to a *Git commit*; a plugin is *hash approved*.

The first time you install a package from a source that does not sign, a **trust card** opens before anything is
queued. It names the package's source and commit, its downloads and maintainer, says *Runs inside Emacs as you: it
can read your files and reach the network.*, and lists every package it brings that is not installed and comes from
an unsigned source too ("It also brings 3 unsigned packages it needs: magit-section, transient, with-editor"). After
the install drgnx pins the package's hash in the lock, so a later sync installs exactly that file.

| On the card | VS Code | Emacs | Vim |
|---|---|---|---|
| Install | `i` | `i` | `i` |
| Cancel | `q` | `q` | `q` |

**Install** queues the install and remembers, on this machine, that you saw the card for that package and the ones it
brings (`~/.local/state/drgnx/extensions/trusted.eld`): the card does not come back for them here, and does on a new
machine. **Cancel** queues nothing. A signed package installs with no card. The card is only ever opened by your own
Install: nothing that runs by itself (a timer, a hook, an agent) can open it, answer it or install anything. An agent
can only suggest a package, and its suggestion has no Install button.

Text that comes with a package and is not yet installed code (a readme fetched from its archive, a reviewed update,
the files of a package you have not installed) is shown as **inert text**: no mode runs on it, no local variable or
`-*- eval: … -*-` line is obeyed, no link in it runs anything, and it is never passed to an agent as an instruction. A
reviewed update is coloured as a diff, and only as a diff.

## Review before an update

`drgnx-extensions-review` lists packages (`magit`) and archives (`"melpa"`) whose updates you want to read before they
install. For those, **Update** first downloads the update and checks it, in the background (`drgnx upgrade --only
magit --stage`); the package's page then shows the version and hash it fetched and what differs from the copy you
have, file by file. **Apply update** installs exactly that download (`drgnx upgrade --staged`, which checks its hash
again); **Discard** forgets it. If another review downloaded something else in between, Apply refuses and asks you to
Update again. **Update All** leaves these packages out and says which wait for your review.

## Generations and rollback

Every change to your packages keeps the state before it as a generation (the newest five, and any a running session
still uses). `@generations`, or the end of the list, shows each with its time, note, the packages that differ from the
one before, whether a session uses it and its size. On a file system without clones it says each change copies the
packages twice. **Roll Back Packages** (the palette, or on a generation) runs a job that puts that generation back.

## Restarting

A session keeps the packages it loaded, so an update or a rollback is used after a restart. **Restart drgnx** (the
header button when updates wait, and the palette) asks about unsaved work first, then starts drgnx again with your
windows. When this drgnx is the `drgnx.service` daemon it restarts the unit instead (`systemctl --user restart drgnx`).

## Updates

With `drgnx-extensions-check-updates` set to `daily` (the default) drgnx reads the archives once a day in the
background, the first time at least ten minutes after it started and only while you are idle, and when you open the
Updates list on an older catalog. `manual` reads them only when you run **Refresh Extensions**. The status bar shows
*3 updates* and a restart mark when there is something to see.
## When a restart is needed

Most changes the Extensions view makes work at once, in the drgnx you are using:

- **A new package works at once.** Its commands, modes and keys are there as soon as the install ends, and a module
  that was waiting for it starts.
- **An update of a package you have not used yet** in this session loads the new version when you first use it.
- **An update of a package already loaded** keeps the version that is running, with everything it needs, until you
  restart drgnx; its row says "Restart to use 4.2 (4.1 is running)". Files of it that load later still come from
  the running version (drgnx keeps a copy of them for this session), never half from the new one.
- **Removing a package already loaded** turns its modes off at once: a buffer in one of its major modes takes the
  mode its file gets without it, and its buffer minor modes go off (other packages' modes stay on). The rest of its
  code stays loaded until you restart; its row says "Restart to finish removing".
- **A failed or stopped change** leaves the session as it was.

A row says "restart drgnx" at once when its files are gone with no copy kept, for instance a package you installed
with `M-x package-install` since the last change and then removed or replaced.

drgnx keeps the copies a running session uses (`~/.local/state/drgnx/elpa-in-use/`) until that session ends; a sync
from the command line or from onboarding keeps its usual advice to restart drgnx. Developers: [live
activation](../develop/extensions.md#live-activation).

## In one project

A package's page can turn the package off **in the project you are in** (its row says "Off in this project"). Its
file modes and buffer modes are then off there: a file it would open in its mode opens in the mode it would get
without the package (`.rs` in `rust-ts-mode` when `rust-mode` is off, for instance), and its buffer minor modes do not
turn on in that project's files. Other projects, and buffers that are not files (`*scratch*`, Magit's), are not
changed. Turning it off or on again applies at once: the project's open files take their modes again.

- Only a package that adds file modes or buffer modes and nothing else can be off in one project. One that changes
  Emacs as a whole (hooks, advice, global modes or keys, a theme: Magit, for instance) says "On in every project: it
  changes Emacs as a whole" and has no switch.
- The choice is yours: it is saved in your private workspace file for that project (`~/.config/drgnx/workspaces/`),
  never in the project's shared `.drgnx/settings.el`. A project's shared settings may list packages in
  `drgnx-packages-off` too ("Off in this project by the project's shared settings").
- No agent can change it.
- `drgnx doctor` says when an open file still has the mode of a package that is off in its project (after a hand
  edit of the setting): `M-x normal-mode` there sets it right.

Developers: [in one project](../develop/extensions.md#in-one-project).

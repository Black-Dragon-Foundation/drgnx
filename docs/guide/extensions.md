# Extensions

One list for everything that extends drgnx: packages, plugins, the editor's modules and Emacs's built-ins. Open it
with `C-S-x` (VS Code keys), `SPC x` (Vim keys) or **Open Extensions** in the palette and the View menu.

The editor never installs anything by itself and never waits for the network. A click on Install, Update or
Uninstall is queued and run by a background job; the row shows how it goes (`◎ native 14/37 · 12s`) and what came of
it. `C-g` never stops a job; **Cancel** (`k`, Vim `x`) does.

## The list

Rows are grouped in sections: **Installed**, **Updates**, **Recommended** (below), **Plugins**, **Built-in** and **Generations**. Each row has the kind's mark
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

Every command is also in the palette, under Extensions: **Open Extensions**, **Search Extensions**, **Extension
Details**, **Install Extension**, **Update Extension**, **Update All Extensions**, **Uninstall Extension**, **Turn
Extension On or Off Here**, **Refresh Extensions**, **Cancel Extension Job**, **Show Extension Job Log**, **Roll Back
Packages**, **Restart drgnx**, **More About Extension**, **Show Recommended Extensions**, **Show Suggested Extension**,
for plugins **Install a Plugin from a Folder**, **Approve Plugin**, **Turn Plugin On or Off**, **Move Plugin Up**,
**Move Plugin Down**, **Replace Plugin** and **Remove Plugin**, and, for the trust card and a reviewed update,
**Install After the Trust Card**, **Cancel the Trust Card** and **Apply Reviewed Update**. The row commands act on the row at point; with the search or a page open they act on that page.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `drgnx-extensions-check-updates` | `daily` | `daily` reads the archives once a day in the background; `manual` only on **Refresh Extensions** |
| `drgnx-extensions-review` | none | packages and archives (`"melpa"`) whose updates you read before they install |
| `drgnx-extensions-recommended` | none | the packages a project recommends (its shared `.drgnx/settings.el` or your private workspace file) |
| `drgnx-packages-off` | none | packages turned off in one project (your private workspace file, or the project's shared settings) |
| `drgnx-extensions-list-density` | `comfortable` | `dense` keeps one line a row |

The first four are on the settings deny-list: no agent changes them. Settings → Extensions lists the packages you asked
for, read-only, from the lock.

## A page for each extension

`RET` on a row opens its page in a preview tab that the next page replaces; `RET` again on the same row keeps it. The
page has the name, the versions, where it comes from and how far to trust that, the maintainer, the address, **Why**
it is here (*you (Extensions) · needed by forge · config.el:31 (:ensure)*; the other words are *module NAME*,
*packages.eld* and *installed by hand*, for a package with no hash in the lock), and, for code, the line every extension
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
sign their packages, and drgnx checks the signature: *signed* once installed, *signed archive* before (the sync
checks the signature before it installs). MELPA and stable MELPA do not sign (*unsigned archive*); a directory archive
is *local*; a Git package is pinned to a *Git commit*; a plugin is *hash approved*.

The first time you install a package from a source that does not sign, a **trust card** opens before anything is
queued. It names the package's source and commit, its downloads and maintainer, says *Runs inside Emacs as you: it
can read your files and reach the network.*, and lists every package it brings that is not installed and comes from
an unsigned source too ("It also brings 3 unsigned packages it needs: magit-section, transient, with-editor"). A
package it needs that the catalog could not look up is named ("Not checked: …"), never left out; when the package's
own lookup fails the card says "Could not check what NAME needs" and has no Install. After the install drgnx pins the
package's hash in the lock, so a later sync installs exactly that file.

| On the card | VS Code | Emacs | Vim |
|---|---|---|---|
| Install | its button only | its button only | its button only |
| Cancel | `q` | `q` | `q` |

No key installs from the card: the list's `i` opens it, so a second `i` must not install what you have not read.
Click **Install**, or move to it and press `RET`.

**Install** queues the install and remembers, on this machine, that you saw the card for that package and the ones it
brings (`~/.local/state/drgnx/extensions/trusted.eld`): the card does not come back for them here, and does on a new
machine, unless the package now needs an unsigned package you never saw a card for: then its card opens again. **Cancel** queues nothing. A package from GNU ELPA or NonGNU ELPA (signed, or from a signed archive)
installs with no card. The card is only ever opened by your own
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
have, file by file. An update that brings new versions of packages it needs downloads those too, and the page shows
each of them the same way. **Apply update** installs exactly that download, all of it (`drgnx upgrade --staged`,
which checks its hashes again); **Discard** forgets it. If another review downloaded something else in between, Apply
refuses and asks you to Update again. **Update All** leaves these packages out and says which wait for your review.

## Recommended

**Recommended** lists, for the project you last opened a file in, in this order and each once:

1. the packages the project's `drgnx-extensions-recommended` names (its shared `.drgnx/settings.el` or your private
   workspace file);
2. the packages Emacs suggests for files the Explorer has already listed in the project (Emacs's own
   `package-autosuggest.eld`: a `.cs` file brings `csharp-mode`, a `.csv` file `csv-mode`). Only folders the Explorer
   has shown count: nothing reads the project's folders for this;
3. the packages a module that is on still waits for.

The first file you open in a project that recommends something posts one notice, "This project recommends 3
extensions"; its **Show** opens the list at `@recommended`. A recommendation is a row with your **Install** button and
nothing else: a repository's settings can name packages, but they never install, queue or trust one. Install goes
through the trust card like any other. **Show Recommended Extensions** in the palette does the same for the project you
are in.

## Suggested by an agent

An agent may suggest a package or a plugin with its `extensions_suggest` tool (docs/guide/agents.md). You get a notice
whose title the hub writes from what it knows, "s1 suggests magit (MELPA)": the session's id, the package's name and
its archive, never the agent's words. The agent's reason is shown only quoted in the notice's details, on one line, at
most 280 characters, with control and direction-changing characters taken out. The notice opens the package's page;
nothing on it installs. Your **Install** on that page is the only way in, through the trust card. One package has one
open suggestion, however many sessions suggest it; a session makes at most three; when the last session that
suggested it ends, the notice goes.

No agent installs, approves or trusts an extension: the tools agents have cannot answer a card; the hub refuses an
agent's job that would change your packages (`drgnx upgrade`, `bin/drgnx pkg`, `drgnx-pkg`, or an Emacs whose Lisp
calls `package-install` and its kin, also inside `sh -c`) before it starts, whatever the sandbox would allow; and `drgnx-extensions-review`, `drgnx-extensions-recommended`,
`drgnx-extensions-check-updates` and `drgnx-packages-off` are on the settings deny-list, so `settings_change` refuses them under any grant.

## Generations and rollback

Every change to your packages keeps the state before it as a generation (the newest five, and any a running session
still uses). `@generations`, or the end of the list, shows each with its time, note, the packages that differ from the
one before, whether a session uses it and its size. On a file system without clones it says each change copies the
packages twice. **Roll Back Packages** (the palette, or on a generation) runs a job that puts that generation back.

## Restarting

A session keeps the packages it loaded, so an update or a rollback is used after a restart. **Restart drgnx** (the
header button when updates wait, and the palette) asks about unsaved work first, then starts drgnx again with your
windows. When this drgnx is the `drgnx.service` daemon it restarts the unit instead (`systemctl --user restart drgnx`);
on macOS, when it is the daemon of drgnx's launch agent, launchd restarts it (`launchctl kickstart -k`).

## Updates

With `drgnx-extensions-check-updates` set to `daily` (the default) drgnx reads the archives once a day in the
background, when you have been idle for ten minutes and the catalog is a day old (never at startup), and when you
open the Updates list on an older catalog. `manual` reads them only when you run **Refresh Extensions**. A change of
the setting applies at once, without a restart. The status bar shows
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

## Plugins

Installed [plugins](plugins.md) are rows of the list like packages (Plugins section, `@plugins`, `@kind:plugin`), with
the hub's own state on the row: *not approved*, *changed*, *disabled*, *broken*, and for an approved plugin *on* or *off*.
`@enabled` and `@disabled` read the same on and off. "On" means the plugin is approved and listed in your plugins setting
(`drgnx-agents-plugins`); a plugin row says "hash approved", never "signed". A plugin that waits for you (not approved,
or changed) is marked with the attention colour. Settings → Plugins and the plugin notice open this view.

A plugin's page is the plugins page: its state and hash, what it declares (abilities, hooks with their verdicts and
reach, hosts), what it sees, and "In this project". Above those, for a plugin that **changed** since you approved it,
the page leads with **what the new version adds**: new hosts, new abilities, new hooks, a new verdict (a `change` at a
point where it only allowed or denied before), and a hook that now matches more tools, tool kinds or paths. When drgnx
does not know what you approved before (an approval from an older drgnx), the page says *What you approved before is
not known: read the whole reach below* instead, in the attention colour. Under the header the buttons are:

- **Approve** (the page's button, or the command *Approve Plugin*): sends the hash the page showed you. If the files
  changed since, the hub refuses and the page shows the new state.
  If the page was drawn again with another hash while you had it open (the plugin changed), the first Approve only
  says so: read the page again, then Approve.
- **Turn on / Turn off:** adds the plugin to the end of your plugins setting or takes it out, so the order of the hooks
  stays yours. **Move up / Move down** change that order (the plugin has to be on).
- **In this project:** as on the plugins page: the project's own plugin list, written to your private workspace file.
- **Replace…** (a newer copy from a folder: the plugin is *changed* until you approve it) and **Remove** are background
  jobs. *Install a Plugin from a Folder* is in the palette. Nothing here approves for you.
- **Remove** asks first ("Remove plugin NAME and what it stored?"), unlike a package's Uninstall: a rollback brings a
  package back, but nothing brings back a removed plugin or what it stored.

## In one project

A package's page can turn the package off **in the project you are in** (its page says "Off in this project", and
its **Turn off in this project** button becomes **Turn on in this project**); `p` on its row in the list does the
same. "The project you are in" is the project of the file you opened Extensions from. Its
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

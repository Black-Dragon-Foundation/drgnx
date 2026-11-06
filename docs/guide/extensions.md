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

## Updates

With `drgnx-extensions-check-updates` set to `daily` (the default) drgnx reads the archives once a day in the
background, the first time at least ten minutes after it started and only while you are idle, and when you open the
Updates list on an older catalog. `manual` reads them only when you run **Refresh Extensions**. The status bar shows
*3 updates* and a restart mark when there is something to see.

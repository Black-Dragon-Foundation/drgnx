# Your files

drgnx keeps its settings in a few small text files. You can edit them in any editor, and drgnx reads them again
when they change. [The reference](../reference/config.md) lists each file, its keys and what they mean.

## Where drgnx keeps its files

| Kind | Folder | What is in it |
| --- | --- | --- |
| config | `$DRGNX_CONFIG_DIR`, else `$XDG_CONFIG_HOME/drgnx`, else `~/.config/drgnx` | your settings: the folder that travels to your other machines ([second-machine.md](second-machine.md)) |
| state | `$XDG_STATE_HOME/drgnx`, else `~/.local/state/drgnx` | what drgnx remembers on this machine: the workbench, reports, last good copies, logs |
| cache | `$XDG_CACHE_HOME/drgnx`, else `~/.cache/drgnx` | what can be made again: downloaded packages, native code, a source build |
| data | `$DRGNX_DATA_DIR`, else `$XDG_DATA_HOME/drgnx`, else `~/.local/share/drgnx` | this machine's packages, and files that must not travel |

- **Only an absolute value counts.** A variable that is unset, empty, relative (`config`) or starts with `~` means the
  default, as the XDG spec says (a relative one would otherwise mean wherever drgnx happened to start). `bin/drgnx`,
  `install.sh` and drgnx itself follow the same rule, so they always agree on the folder. `drgnx doctor` warns in its
  `config-dir` check when one of these variables is set to a value that does not count, and names the folder used instead.
- The doctor's `state-dir` check warns when the state folder lies inside the temporary directory: TRAMP then asks about
  autosaving on a local temporary directory, and the state goes with the next cleanup.
- **An old `~/.config/drgnx` still works.** When `XDG_CONFIG_HOME` is set, `DRGNX_CONFIG_DIR` is not, there is no
  `$XDG_CONFIG_HOME/drgnx` yet and `~/.config/drgnx` exists, drgnx keeps using `~/.config/drgnx`. `drgnx doctor` warns in
  its `config-dir` check and says where to move it; once moved, drgnx uses the new folder.
- A folder in a remote buffer's directory is never meant: drgnx works these folders out locally, so a remote buffer
  never makes it connect to the host.

## Files a project carries

Some settings can also come from a project, in its `.drgnx/` folder. `.drgnx/large-files.eld` is someone else's
text, so it can only make drgnx do less: it can lower your `:ask-above` and `:chunks-above` from `large-files.eld`,
never raise them or set the chunk size ([large-files.md](large-files.md#the-settings)). With a mistake it is ignored,
with one notice.

## What a drgnx data file may contain

drgnx's files hold data, never code: drgnx reads them, it never loads them. A file may contain:

- numbers: `80`, `-3`, `1.5`, `#x1F`, `#o17`, `#b101`, `#24r1k` (whole numbers up to 64 bits);
- strings, with any escape: `"tab\there"`, `"é"`, `"\N{U+E9}"`;
- characters: `?a`, `?\n`, `?\C-a`;
- symbols and keywords: `fill-column`, `nil`, `t`, `:mode`;
- lists, dotted pairs and vectors: `(a b)`, `(a . b)`, `[1 2]`;
- `'x` and `#'f`, which read as `(quote x)` and `(function f)`;
- comments (`;`) anywhere.

These are mistakes, at the line and column where they start (the file falls back to its last good copy, as below):

- a backquote or a comma (`` `(a ,b) ``): that is code. Write the value itself, `(a b)`;
- any other `#` syntax: `#s(…)`, `#(…)`, `#[…]`, `#1=`, `#$`, `#:x` and the rest;
- a byte above 127 written as `"\xe9"`, `"\351"` or `"\M-a"`: write the character `"é"`, or `"é"`;
- a whole number beyond 64 bits;
- text that is not valid UTF-8.

Inside a string or a comment these characters are just text: `` "`(a ,b)" `` and `;; ,x` are fine, and so are the
characters `` ?` ``, `?,` and `?#`.

## When a file has a mistake

A file with a mistake (a missing bracket, a value of the wrong kind) is never applied half way. You see one
notice that names the file, the line and what is wrong. Until you fix it, drgnx uses **the last good copy** of the file:
the version it last read without a mistake, which it keeps for you per machine. If the file never read well, it uses
the defaults.

- `drgnx doctor` names the same mistakes in its `config-files` check, as "FILE line L: TEXT".
- Whatever changes a file for you (a setting you change in Preferences, say) **refuses** a file with a mistake, and
  tells you so. It never rewrites a file it could not read, and it never rebuilds one from the keys it knows: your
  comments and the keys it does not know stay as you wrote them, byte for byte.
- **Open Config File…** (Preferences, in the palette) opens the file at the mistake's line and column.
- **Reset Config File…** puts the file back to drgnx's defaults, after asking. The old file is backed up beside it first.
- A file made by an older drgnx is read as the current format in memory, and left alone. **Migrate Config File…**
  writes it in the current format (with a backup); nothing does that by itself.

## Backups, locks and last good copies

Next to a file `NAME` you may see:

- `NAME.bak-DATE-TIME-MS`: a backup made before a reset, a migration, or the rewrite of a state file that could not be read.
  drgnx keeps the newest 3 and deletes the older ones. The time is UTC, so the names sort in time order.
- `.NAME.lock/`: a folder that exists while drgnx changes the file, so that two drgnx processes (or drgnx and a
  script) never change it at once. It goes when the change is done. If a process dies holding one, the next
  change finds it stale after ten seconds and removes it. Deleting it by hand is safe when no drgnx is changing the file.
- `.NAME.tmp-XXXXXX`: the new content, written in full before it is renamed over the file, so a reader sees the old
  file or the new one, never half of one. One left behind means a write was cut short; it is safe to delete.

The last good copies are not next to the files: they are in `config-good/` in drgnx's state folder, one per file,
and drgnx writes one only when the file read well.

## Two machines, one folder

If you share your config folder between machines (a synced folder, a dotfiles repository), the machines may run
different drgnx versions.

- **Unknown keys are kept.** A key your drgnx does not know (written by a newer drgnx, or a typo) is left exactly
  where it is whenever drgnx changes the file. `drgnx doctor` lists them as information.
- **A newer file is read-only.** A file written by a newer drgnx is used when this drgnx can understand it, and
  never changed: drgnx here refuses to write it, and the doctor warns "written by a newer drgnx: update drgnx here".
  Update drgnx on this machine to change that file here.
- An older drgnx never rewrites a file to a newer format on its own, so a machine that only starts drgnx leaves the
  shared folder alone.

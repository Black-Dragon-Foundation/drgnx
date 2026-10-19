# Your files

drgnx keeps its settings in a few small text files. You can edit them in any editor, and drgnx reads them again
when they change. [The reference](../reference/config.md) lists each file, its keys and what they mean.

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

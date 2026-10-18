# Keyboard Shortcuts editor

**Preferences: Keyboard Shortcuts** (module `tools/shortcuts`) lists every drgnx command with its keys, as VS
Code's Keyboard Shortcuts page does, and changes them in your `keys.eld` ([keys.md](keys.md)). Keys: `C-k C-s`
(VS Code), `SPC h s` (Vim); with Emacs keys it is in the palette and the Options menu. The key sheet (Help:
Keyboard Shortcuts, `C-k C-r` / `C-h C-k` / `SPC ?`) is the read-only overview.

## The page

One line per command:

| Column | What it shows |
|---|---|
| Command | its category and title, as in the palette |
| Keys | its keys; `†` marks a key a terminal cannot send (see below) |
| Source | the profile the key comes from (VS Code, Emacs, Vim), `keys.eld` when you changed it, or `package` for a key Emacs or a package bound to the command itself |
| Where | `global`, or the view or mode the key works in (the keymap it is bound in) |

A `!` at the start of a line marks a key conflict; hover over it to see with which command and where. A conflict is
only one within the same place: the same key in two views is not.

A profile's key over one of Emacs' own keys is not a conflict: the profile chose it (VS Code's `C-k` chords take
`C-k`, `kill-line`, as a prefix). Hover over the Where column to see what it is over ("Over Emacs' kill-line
(C-k)"); the key sheet and the doctor list these too. The same key in your `keys.eld`, a key another active layer
claims (the Emacs layer's keys in "Emacs editing + VS Code app keys", Vim's keys) and two drgnx commands on one
key are conflicts.

The first line shows the key profile in use, with **[Switch Profile…]**: VS Code, Emacs or Vim keys, or a
combination. It applies at once and is kept in `keys.eld` (as Keyboard Profile… does).

**Suggestion:** a command you ran 10 times or more from the palette in the last seven days, and that has no key,
gets a line at the top: "You ran … N times from the palette this week; give it a key?", with a button that records
one. The palette's counts stay on this machine (`command-usage.eld` in drgnx's state directory).

## Keys on the page

| Key | What it does |
|---|---|
| `RET` | Change Keybinding: record new keys for the command on the line, in place of its key (asks which one when it has several) |
| `a` | Add Keybinding: record one more key, keeping its keys |
| `/` | Filter by text in the title or category; the list follows as you type (empty: all; `C-g` puts back the filter you had) |
| `k` | Record Keys (Filter): press a key or a chord; the page shows the commands on it, or on keys that start with it. Again: off |
| `c` | Show Conflicts only (again: all) |
| `n` | Show Commands Without a Key only |
| `m` | Show Changed by Me only (the commands your `keys.eld` changes) |
| `u` | Undo Last Change |
| `r` | Reset Keybinding: the command gets its profile's keys again |
| `R` | Reset All Keybindings, after a confirmation |
| `p` | Switch Profile… |

The filters combine. These keys are the same in every profile (in the Vim profile the page starts in Emacs state).

## Recording keys

After `RET` (or `a`), press the keys:

- one key, such as `C-c y` or `<f9>`; or a **two-key chord** such as `C-k C-o`: after the first key the editor waits
  one second (`drgnx-shortcuts-chord-wait`) for a second one;
- `C-g` or `ESC` cancels, as the first or the second key; nothing is written.

In a terminal, Meta keys can't be recorded (a terminal sends `M-x` as `ESC x`, and `ESC` cancels): use a graphical
frame, or write the key in `keys.eld`.

A key in the global keymap that starts with a character typed as is (a letter, a capital letter, `RET`, `TAB`) is
refused: it would stop you typing that character. Use a modifier, or a chord that starts with one. `C-x`, `C-c`,
`C-h` and `ESC` alone are refused there too: every Emacs key that starts with them would go. Record a chord that
starts with one instead (`C-c k`).

If the key is taken in the same place, drgnx says by what, and asks:

- **Replace:** the other drgnx commands lose that key;
- **Keep both:** both keep it, and the conflict is listed (`!`);
- **Cancel:** nothing changes.

A **prefix clash** is flagged the same way: the key is the start of another command's key (recording `C-c e` when
`C-c e C-x` is bound there), another key is the start of it, or it would replace one of Emacs' own prefixes
(`M-g`). A key bound by Emacs or a package in that place is named too.

## Terminal mark

`†` marks keys a terminal without the kitty keyboard protocol cannot send: keys with Super (`s-`), Hyper or Alt,
`C-S-` on a character (`C-S-p`), and `C-` on a character other than a letter, `@ [ \ ] ^ _ ?` or space (`C-.`,
`C-1`, `C-/`). They work in a graphical frame.

## Undo and reset

Every change is written to `keys.eld` at once, keeping your comments, `:layers` and the other entries, and the keys
apply without a restart. `u` takes back the last change, also after a restart; a Replace (the key taken from another
command and given to this one) is one change. If `keys.eld` was changed since (by you, another session, or
Keyboard Profile…), Undo says so and changes nothing. A `keys.eld` that does not read is shown at the top of the
page and never written.

`r` removes the command's entry from `keys.eld`, so it has its profile's keys again. `R` does that for every command
(`:layers` and your comments stay); Undo brings them back.

## How it works

`modules/tools/drgnx-shortcuts.el` reads the last key resolution (`drgnx-keys-last`: bindings, conflicts, layers),
the registry and `keys.eld`, and writes only through `core/drgnx-keys-edit.el`. Tests:
`test/unit/mod-shortcuts-test.el`.

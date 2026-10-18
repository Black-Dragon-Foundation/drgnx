# Search and replace

One interface for renaming a symbol and replacing text, like VS Code's Search view (module `tools/replace`): the
**Search view** in the sidebar works on the project or one file, and the **find bar** above an editor works on its
buffer.

## The Search view

**Replace in Files** shows the sidebar's Search view (the sidebar's other view is the Explorer; **View: Explorer**
brings it back) with the word at point, or the selected text, in **Find**. It has:

- **Find** and **Replace**;
- toggles: **⟨⟩ Symbol**, **Aa** (match case), **ab** (whole word), **.\*** (regular expression);
- the scope: **Project** (the project of the file you were in) or **This file**;
- **Include** and **Exclude**: globs, comma-separated (`src/**, *.el`); a glob without a slash matches at any depth;
- **Replace All** and **Undo**, then a status line (how many results, what the last replacement did).

The search runs a quarter of a second after you stop typing (`RET` in a field searches at once): ripgrep when it is
installed, else `git grep` or grep, in the background. Results stream in, grouped by file. Each match is a row with
a tick box and shows the change as old → new (the old text struck through). A file's box ticks or unticks all its
matches. A click or `RET` on a row opens the file at the match.

## Symbol or text

**Symbol** is on when point is on a name the buffer's language server can rename (Replace in Files turns it on by
itself there); **Rename Symbol** always asks for it and puts you in Replace. With Symbol on, the list is the
server's rename edits: only real uses, never comments or look-alikes. Include, Exclude, Aa, ab and .\* do not
apply and are greyed out. Typing other text in Find turns Symbol off: that is a text search. Without a server that
can rename, the status line says why and the view searches the text.

With **.\*** on, Replace can use the regexp's groups: `\1`, `\2`.

## Replacing and undo

**Replace All** writes every ticked match; **Replace This Match** writes the one on the row, ticked or not. Each
match is checked against the file as it is now: a match whose text changed since the search is skipped and listed
with the reason, never written blind. A file's replacements are one change; files are saved, except a file whose
buffer held unsaved edits: it gets the replacement and stays unsaved, as in VS Code. **Undo Replace** (the view's
Undo button) puts every file of the last replacement back in one step; a file edited since is left alone.

## The list stays current

When a listed file changes — you edit its buffer (saved or not), or something writes it on disk (an agent, a
checkout) — its rows are searched again half a second later, from the buffer when it is open, so unsaved edits count.
A match that was unticked stays unticked when the text around it is the same. Changes on disk are noticed for the
first 200 listed files (`drgnx-replace-watch-limit`); with more, the view searches again when it is shown. A symbol
list is never re-asked of the server by itself: when the code changes, the status line says so; run Rename Symbol
again.

## The find bar

**Replace in File** opens a two-line bar above the editor with Find, Replace and the same toggles, for that buffer.
Every match is highlighted, the current one stronger, with "2 of 5". `RET` goes to the next match, `S-RET` to the
previous one, `C-RET` replaces all of them (one undo step; the buffer is left unsaved), `RET` in Replace replaces
the current one, `ESC` closes the bar. **Show all in sidebar** moves the search, with its toggles, to the Search
view, scope This file.

## Keys

| Command | VS Code | Emacs | Vim |
|---|---|---|---|
| Replace in Files | `C-S-h` | `C-c s r` | `SPC s r` |
| Rename Symbol | `<f2>` | palette | `SPC c R` |
| Replace in File (the find bar) | `C-h` | palette (`M-%` stays query-replace) | palette |
| Replace All | `C-M-<return>`, `C-<return>` | `C-c C-c`, `C-<return>` | `C-c C-c`, `C-<return>` |
| Replace This Match (on a row) | `C-!` | `C-c C-r` | `C-c C-r` |
| Undo Replace | the Undo button | `C-c C-u` | `C-c C-u` |
| Next Match | `<f4>` (anywhere) | `C-c C-n` | `C-c C-n` |
| Previous Match | `S-<f4>`, `S-<return>` | `C-c C-p`, `S-<return>` | `C-c C-p`, `S-<return>` |
| Close Find Bar | `<escape>` | `<escape>` | `<escape>` |

Except where marked, the keys work in the Search view and the find bar, their fields too; `RET` in a find bar field
is its next match (in Replace: replace it). Next and Previous Match show the match in the editor. In the VS Code
profile `C-h` replaces Emacs' help prefix (the conflict is listed in Keyboard Shortcuts). Every command is in the
palette, category Search.

## Tests

`test/unit/mod-replace-engine-test.el` (the engine: ripgrep, git grep and grep, stale matches, symbol edits, undo) and
`test/unit/mod-replace-view-test.el` (the view, the find bar, 10k matches streaming); `test/ui/editor-m11c1-test.el` (`drgnx test --ui`) walks the Search view with results, the find bar, the Agent and Zen layouts, the Browser layout without WebKit, the Live view on a mock browser and the Keyboard Shortcuts editor recording a chord on a graphical frame, with a screenshot of each. The perf workload
`replace-typing` types in a file while the Search view lists 10k matches ([perf.md](../develop/perf.md)).

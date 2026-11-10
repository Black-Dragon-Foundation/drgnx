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

The search runs a quarter of a second after you stop typing (`RET` in a field searches at once), in drgnx's hub, in
the background. Results stream in, grouped by file. A search typed before the hub is up (the first seconds after
drgnx starts, or while it restarts) says "Waiting for the hub" and starts when the hub comes; an Emacs without
Nidhogg's view model (Sjá) says it cannot search text (Symbol still works). Each match is a row with
a tick box and shows the change as old → new (the old text struck through). A file's box ticks or unticks all its
matches. A click or `RET` on a row opens the file at the match.

The results update in place: typing a replacement redraws each match's row with its new preview (the rows the window
shows first), and a new search replaces the rows without keeping typing waiting, even over 10,000 matches. The list keeps its place: rows
changing above the ones you look at do not scroll them away. While the Search view is hidden (another sidebar view,
the sidebar closed) it draws nothing; it catches up when it is shown again.

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
with the reason, never written blind. So is every match in a large file open in chunks or raw ("open in chunks:
Large File: Open Whole first"; [large-files.md](large-files.md)). A file's replacements are one change; files are saved, except a file whose
buffer held unsaved edits: it gets the replacement and stays unsaved, as in VS Code. **Undo Replace** (the view's
Undo button) puts every file of the last replacement back in one step; a file edited since is left alone. After
Replace All the list holds what it skipped, each match with why after its text; a new search ticks every match again.

## The list stays current

When a listed file changes on disk (an agent, a checkout, a save) the search runs again half a second later; a
buffer with unsaved edits is searched from the buffer, so its edits count. Replace always reads the files at once, and
checks them, before it writes. Changes on disk are noticed for the first 200 listed files
(`drgnx-replace-watch-limit`). A symbol
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
| Replace in File (the find bar) | `C-h` (Option+Cmd+F on a Mac) | palette (`M-%` stays query-replace) | palette |
| Replace All | `C-M-<return>`, `C-<return>` | `C-c C-c`, `C-<return>` | `C-c C-c`, `C-<return>` |
| Replace This Match (on a row) | `C-!` | `C-c C-r` | `C-c C-r` |
| Undo Replace | the Undo button | `C-c C-u` | `C-c C-u` |
| Next Match | `<f4>` (anywhere) | `C-c C-n` | `C-c C-n` |
| Previous Match | `S-<f4>`, `S-<return>` | `C-c C-p`, `S-<return>` | `C-c C-p`, `S-<return>` |
| Next File | `C-M-<down>` (the Search view) | `C-c M-n` | `C-c M-n` |
| Previous File | `C-M-<up>` (the Search view) | `C-c M-p` | `C-c M-p` |
| Close Find Bar | `<escape>` | `<escape>` | `<escape>` |

Except where marked, the keys work in the Search view and the find bar, their fields too; `RET` in a find bar field
is its next match (in Replace: replace it). Next and Previous Match show the match in the editor; Next and Previous
File select the next or previous file's row. `RET` or a click on a tick box ticks or unticks it. In the VS Code
profile `C-h` is Replace in File in buffers (the conflict with Emacs' help prefix is listed in Keyboard Shortcuts);
the minibuffer keeps `C-h` as help. Every command is in the
palette, category Search.

## Tests

`test/unit/mod-replace-engine-test.el` (writing: stale matches, symbol edits, undo) and
`test/unit/mod-replace-view-test.el` (the view, the find bar; on the virtual clock, the view's own rows Symbol mode
uses: 10k rows streaming and a replacement patching them in slices of at most 576, a new search, a hidden view, no
marker per file); `test/ui/editor-m11c1-test.el` walks the Search view with results, the find bar, the Agent and Zen layouts, the Browser layout without WebKit, the Live view on a mock browser and the Keyboard Shortcuts editor recording a chord on a graphical frame, with a screenshot of each. The perf workload
`replace-typing-rows` types in a file while the hub lists 10k matches, and `search-window` walks Next Match across the
model's window of a 30k-match search ([perf.md](../develop/perf.md)).

When the hub builds the results (`search/grep`, [hub.md](../develop/hub.md)), they also arrive as a model of files and
their matches, and the keys answer from it in Emacs (`drgnx-replace-rows-attached`): Next Match and Previous Match walk
the matches over the file rows, wrapping, and Next and Previous File the files (`down:file`, `up:file`); a tick box (a
button: `RET` or a click) unticks a match (its file's box: all of them) and stays as it is when the hub redraws the
row; a new search empties Sjá's ticked set. Replace All writes the ticked matches from the model's fields, then tells
the hub what it skipped (`search/grep-skipped`): the hub lists those alone, each with why, and stops the search.
`test/unit/replace-rows-nav-test.el` covers these with no hub.

The hub keeps every match but sends the view a window of the rows, the first 200 (the agent panel's shape), and the
totals with `search-grep-done`; the view asks for the next window when its window nears the end of the rows
(`search/grep-look` with `more`), and for the rows up to a match when Next Match or Previous Match goes beyond them
(`upto`; point goes to the row when it arrives).  A match more than 400 rows past the rows sent comes in a block
of rows around it after a gap row ("⋯ N more"), not with every row before it (one patch of 19,000 rows was over the
hub's 16 MiB per client, and it dropped the editor); when the gap row is in sight the view asks for the rows before it
(`fill`), and the gap row goes when they meet the block.  Replace All and the tick boxes read the model, so they act on every
match, not only the rows sent; the file watches follow the model's files too.

A text search is the hub's `search/grep` (the view `search`, the fields' text and
toggles, the folder or file, the include and exclude globs, the replacement), and the results are the hub's rows, a
reset and then each file's header and matches, inserted below the fields by `drgnx-view-apply-patch`.  A new search
makes the hub send a reset and drop the old search's late rows, and the editor drops one that still arrives by its
base.  `search-grep-done` ends the search and gives the count the status line shows; the status line shows
"Searching…" until then.  Typing in the Replace field is `search/grep-replace`: the hub patches the previews and
nothing is searched again.  Symbol mode (the language server's edits) keeps rows of Emacs's own (the `replace-results`
view type), and the view changes between the two with each search; `drgnx-view-old-path` has no Search path of its
own any more (plan sja-complete S2 removed the Lisp text engine).  The file watches stay Lisp: a listed file that changes on disk is searched again through the hub after half a second.  The hub reads the disk, so a file whose buffer has unsaved edits is rescanned by Emacs from the buffer
(`drgnx-replace--scan`, after each search and half a second after an edit), also when the hub found nothing in the file:
those matches take the place of the hub's rows of the file, are counted and are what Replace All and Replace This
write.  Next Match and Previous Match walk them after the hub's matches; they have no tick boxes (they are not in the hub's model); a new search forgets them.  `test/unit/replace-rows-test.el` covers the stream with no hub.

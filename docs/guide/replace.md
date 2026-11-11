# Search and replace

One interface for renaming a symbol and replacing text, like VS Code's Search view (module `tools/replace`): the
**Search view** in the sidebar works on the project or one file, and the **find bar** above an editor works on its
buffer.

## The Search view

**Replace in Files** shows the sidebar's Search view (the sidebar's other view is the Explorer; **View: Explorer**
brings it back) with the word at point, or the selected text, in **Find**. It has:

- the **mode chip** at the left of **Find** (what Find means: **Text**, **Symbol** or **Meaning**; below), and
  **Replace**;
- toggles: **Aa** (match case), **ab** (whole word), **.\*** (regular expression);
- the scope chips, one on at a time (below): **Project** (the project of the file you were in), **This file**,
  **Open**, **Changed**, **Staged**, **Branch ▾**, and **±** (changed lines only);
- **Include** and **Exclude**: globs, comma-separated (`src/**, *.el`); a glob without a slash matches at any depth;
- **Replace All** and **Undo**, then a status line (how many results, what the last replacement did).

The search runs a quarter of a second after you stop typing (`RET` in a field searches at once), in drgnx's hub, in
the background. Results stream in, grouped by file. A search typed before the hub is up (the first seconds after
drgnx starts, or while it restarts) says "Waiting for the hub" and starts when the hub comes; an Emacs without
Nidhogg's view model (Sjá) says it cannot search (Rename still works). Each match is a row with
a tick box and shows the change as old → new: only the characters that change are tinted, the old ones struck
through (`foo` → `foobar` shows `foo` with `bar` added). A file's box ticks or unticks all its
matches. A click or `RET` on a row opens the file at the match.

The results update in place: typing a replacement redraws each match's row with its new preview (the rows the window
shows first), and a new search replaces the rows without keeping typing waiting, even over 10,000 matches. The list keeps its place: rows
changing above the ones you look at do not scroll them away. While the Search view is hidden (another sidebar view,
the sidebar closed) it draws nothing; it catches up when it is shown again.

In code files, a dim label row (`ƒ` and a name) goes above the first match inside each function, type or other
definition, so you see where a match is without opening it; the next matches in the same definition follow without
one, and a match outside every definition has none. Hover a label for the names around it (`impl P › get`). Labels
are not matches: no tick box, and Next Match skips them. Turn them off with the setting `drgnx-search-context`.

## Scopes

The scope chips say which files a Text search reads; **Include** and **Exclude** still narrow them. Clicking a chip,
or **Search: Next Scope** (`M-s` in the view; `C-c C-o` in the Emacs and Vim profiles), searches again.

- **Project**: every file of the project, as the ignore rules say. **This file**: the file the view was opened from.
- **Open**: the files open in the editor under the project.
- **Changed**: the working tree's modified, added and untracked files. **Search: In Changed Files** (`C-k C-g`;
  `C-c s g`; `SPC s g`) opens the view there.
- **Staged**: the files with staged changes. Their text in the working tree is what is searched (what an edit would
  change).
- **Branch ▾**: the files changed since this branch left its base, and the working tree's changes. The base is the
  branch's upstream, else `main`, else `master`; pressing Branch again opens its menu (the upstream and the branches
  committed to lately, or any name you type), and the chip shows the base you picked. On a detached HEAD or a branch
  with no commit yet there is no base to take: the status line asks, with a **Choose…** link. **Search: In Files
  Changed on This Branch** (`C-c s b`; `SPC s b`; the palette in VS Code) opens the view there.
- **±** (Changed, Staged and Branch): only matches on lines the changes added; a new file counts whole. For a staged
  file that also has unstaged changes, its working-tree changes count.

The status line says what a git scope searched ("Changed: 7 files · 2 submodules not searched · 1 deleted"), and the
chip shows the count. Submodules and deleted files are not searched; a renamed file is searched at its new name. An
empty scope says why ("nothing staged"); a folder outside git says so. Symbol and Meaning search the whole project.

## Recent and saved searches

Every search that stood for the typing pause is kept, per project, the last 50: its mode, words, toggles,
replacement, scope and globs. **Previous Search** and **Next Search** (`Up` and `Down` in Find in the VS Code profile;
`M-p` and `M-n` in the view in the Emacs and Vim profiles) walk them, each restored whole and run; Next Search past the
newest gives back what you had.

With Find empty, the view lists the project's **Saved** searches, then its last 8 **Recent** ones; a click runs one.
**Save This Search** (the ☆ button; `C-k C-b`; `C-c C-w`) keeps the view's search under a name, the words by default.
A saved search's row has **pin**, **share** and **×** (delete). A pinned search shows its live count above the
results ("TODOs · 3"), counted again at most every 5 seconds, when the view searches, and only while the view shows.
**share** writes it into the project's `.drgnx/searches.eld`, so the team gets it; searches found there are listed too,
read as data only (nothing in that file runs). **Search: Run Saved Search…** (`C-c s S`; `SPC s S`; the palette)
picks one by name. drgnx keeps them in its own state, not in the project.

## Modes: Text, Symbol, Meaning

The mode chip says what Find means; clicking it, or **Search: Next Mode** (`M-m` in the view; `C-c C-m` in the Emacs
and Vim profiles), goes Text → Symbol → Meaning → Text and searches again. The palette has one command per mode
(**Search: Text Mode**, **Symbol Mode**, **Meaning Mode**). With Find empty, the status line says what to type.

- **Text** (the default): the files' text, with Aa, ab, .\*, the globs and Replace.
- **Symbol**: a name's definitions first, then the lines that use it, from drgnx's code index (Hrafn): each line's
  whole-word uses of the name are the matches. A definition's row shows its kind as an icon (`ƒ` a function, `◇` a
  type, `#` a macro, `≡` a variable or constant; hover for the kind) and its signature; the uses inside one
  definition follow a label row naming it (with `drgnx-search-context` on). It is by name only, so same-named things
  in other scopes are listed too, and the status line says so. **Aa** says whether case counts; Replace, the globs,
  ab and .\* do not apply and are greyed out.
- **Meaning**: the code your words describe (the same search as Semantic Search): one row per piece of code found,
  with a score bar (how close it is, against the best one; hover for the score), its symbol and its first line; a
  piece that moved since it was indexed is found where it is now and says `(moved)`. Nothing but the words applies.

Symbol and Meaning only find: Replace All and Replace This say so. A Text search that finds nothing offers **Try
Meaning** on the status line; the view never changes mode by itself. Symbol and Meaning need the index: before it is
built the status line says why.

## Rename

**Rename** is on when point is on a name the buffer's language server can rename (Replace in Files turns it on by
itself there); **Rename Symbol** always asks for it and puts you in Replace. The chip then says **Rename**, and the
list is the server's rename edits: only real uses, never comments or look-alikes. Include, Exclude, Aa, ab and .\* do
not apply and are greyed out. Typing other text in Find, or picking a mode, ends Rename: that is a search. Without a
server that can rename, the status line says why and the view searches the text.

With **.\*** on, Replace can use the regexp's groups: `\1`, `\2`.

## Replacing and undo

**Replace All** writes every ticked match; **Replace This Match** writes the one on the row, ticked or not. Each
match is checked against the file as it is now: a match whose text changed since the search is skipped and listed
with the reason, never written blind. So is every match in a large file open in chunks or raw ("open in chunks:
Large File: Open Whole first"; [large-files.md](large-files.md)), and a binary file, a file that is not UTF-8 or one over
16 MiB. A file's replacements are one change; files are saved, except a file whose buffer held unsaved edits: it gets
the replacement and stays unsaved, as in VS Code. The status line says what happened: "Replaced 58 in 4 files · 2
skipped". **Undo Replace** (the view's Undo button) puts every file of the last replacement back in one step; a file
edited since is left alone and named. After Replace All the list holds what it skipped, each match with why after its
text; a new search ticks every match again.

### How Replace All writes

The hub writes, not the view (the shared write path: [hub.md](../develop/hub.md), "Search writes"). Replace All asks
it for the edit set of the search (`search/edits`: every match but the unticked, each with its line, columns, old and
new text, read from the file as it is then) and then to write it (`search/apply`). A file no buffer of this Emacs
visits is written on disk by the hub, atomically (a temporary file renamed over it, its mode, owner and line endings
kept), and only when its bytes are still the ones the edit set read: else "changed on disk since the preview". A file
this Emacs has open is never written behind its buffer: the hub sends its edits to Emacs, which puts them into the
buffer (each only where its old text still is) as one undo step, saves it when it held no unsaved edits, and answers
with the edits that undo them. Writes to a file take turns with an agent's writes to it (the pair door), so the two
never interleave. Undo Replace is the hub's too (`search/undo`): it puts back each file it wrote, on disk or in its
buffer, unless the file or buffer was edited since; a buffer killed since gets its file put back on disk when it was
saved. Symbol mode's rename sends the language server's edits the same way, as edits the hub is given.

### Preview and the Replace All sheet

**Preview** (the view's Preview button, or Preview This File's Changes on a row) opens the row's file as a read-only
diff in the editor area, "NAME · preview": the file before and after its ticked replacements, the same edit set
Replace All writes (the hub's `search/preview`), each line with its number and the words that change marked. Its header
line says how many of the file's matches are ticked and the lines added and removed; **Open File** opens the file and
**Replace in This File** writes the file's ticked matches only. Each hunk has a band with its tick box, `hunk N` and the
definition it is in (`defun drgnx-gateway--queue`); `a` keeps the hunk (its matches are ticked in the view), `D` drops it
(unticked); the view's boxes and the tile follow each other. A line whose match you unticked stays in the hunk as it
is, marked `← unticked, kept`. With **.\*** on, a groups line under each hunk shows what each group took, `\1 = pending`
`\2 = p`, and `\2 = ∅` in the warning colour for a group that matched nothing, so a wrong group number shows before
anything is written.

**Replace All** first shows the **Replace All sheet**, a box in the middle of the window (the popup lane, modal): every
file with its lines added and removed
and how many of its matches are skipped, the selected file's first hunk, its changed lines (`n`/`p` or the arrows move), what is skipped
and why, and how many files with unsaved edits stay unsaved. **Replace** writes exactly the changes the sheet shows (the
hub's change set); **Cancel** writes nothing. The setting `drgnx-search-preview-threshold` (default 1) is how many
matches it takes to show the sheet; 0 never shows it, and `C-u` Replace All skips it once.

## The list stays current

When a listed file changes on disk (an agent, a checkout, a save) the search runs again half a second later; a
buffer with unsaved edits is searched from the buffer (its text goes to the hub half a second after an edit), so its
edits count, and its matches can be ticked and unticked like any other. Replace always reads the files at once, and
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
| Next Mode (the Search view) | `M-m` | `C-c C-m` | `C-c C-m` |
| Text / Symbol / Meaning Mode | palette | palette | palette |
| Next Scope (the Search view) | `M-s` | `C-c C-o` | `C-c C-o` |
| In Changed Files | `C-k C-g` (anywhere) | `C-c s g` | `SPC s g` |
| In Files Changed on This Branch | palette | `C-c s b` | `SPC s b` |
| Previous / Next Search | `<up>` / `<down>` in Find | `M-p` / `M-n` | `M-p` / `M-n` |
| Save This Search | `C-k C-b` | `C-c C-w` | `C-c C-w` |
| Run Saved Search… | palette | `C-c s S` | `SPC s S` |
| Preview This File's Changes (the Search view) | `C-k C-v` | `C-c C-v` | `C-c C-v` |
| Keep / Drop This Hunk (a preview tile) | `a` / `D` | `a` / `D` | `a` / `D` |
| Replace / Cancel (the Replace All sheet) | `C-<return>` / `<escape>` | `C-c C-c` / `C-c C-k` | `C-c C-c` / `C-c C-k` |
| Next / Previous File (the sheet) | `<down>` / `<up>` | `n` / `p`, `<down>` / `<up>` | `n` / `p`, `<down>` / `<up>` |

Except where marked, the keys work in the Search view and the find bar, their fields too; `RET` in a find bar field
is its next match (in Replace: replace it). Next and Previous Match show the match in the editor; Next and Previous
File select the next or previous file's row. `RET` or a click on a tick box ticks or unticks it. In the VS Code
profile `C-h` is Replace in File in buffers (the conflict with Emacs' help prefix is listed in Keyboard Shortcuts);
the minibuffer keeps `C-h` as help. Every command is in the
palette, category Search.

## Tests

`test/unit/mod-replace-engine-test.el` (the editor's half of a write: edits into an open buffer, stale ones skipped,
symbol edits, undo), `test/conformance/search/write.jsonl` (the hub's: the edit set, writes on disk, a file changed
since, undo) and
`test/unit/mod-replace-view-test.el` (the view, the find bar; on the virtual clock, the view's own rows Symbol mode
uses: 10k rows streaming and a replacement patching them in slices of at most 576, a new search, a hidden view, no
marker per file); `test/ui/editor-m11c1-test.el` walks the Search view with results, the find bar, the Agent and Zen layouts, the Browser layout without WebKit, the Live view on a mock browser and the Keyboard Shortcuts editor recording a chord on a graphical frame, with a screenshot of each; `test/ui/search-view-gui-test.el` walks the hub-fed view (Sjá) through Text with a context label, Symbol, Meaning, a git scope and the empty view's saved and recent searches, the hub's rows handed in as it sends them, a screenshot of each in the evidence folder. The perf workload
`replace-typing-rows` types in a file while the hub lists 10k matches, `search-retype` changes the view's query a
character at a time over 10k matches (each key a search, timed to its first rows and to its end), and `search-window`
walks Next Match across the model's window of a 30k-match search ([perf.md](../develop/perf.md)).

When the hub builds the results (`search/run`, [hub.md](../develop/hub.md)), they also arrive as a model of files and
their matches, and the keys answer from it in Emacs (`drgnx-replace-rows-attached`): Next Match and Previous Match walk
the matches over the file rows, wrapping, and Next and Previous File the files (`down:file`, `up:file`); a tick box (a
button: `RET` or a click) unticks a match (its file's box: all of them) and stays as it is when the hub redraws the
row.  A new search empties Sjá's ticked set but keeps what you unticked: the view sends the unticked matches with it,
and when it ends the hub names the same matches of the new search (by file, the text around the match and its column,
not its line, so lines added above a match keep it), which are unticked again; two matches the hub cannot tell apart
come back ticked.  Replace All sends the hub the unticked matches (`search/edits` `off`) and the hub writes the rest
("How Replace All writes" above); when the write ends the view tells the hub what it skipped
(`search/grep-skipped`): the hub lists those alone, each with why, and stops the search.
`test/unit/replace-rows-nav-test.el` covers these with no hub.

The hub keeps every match but sends the view a window of the rows, the first 200 (the agent panel's shape), and the
totals with `search-run-done`; the view asks for the next window when its window nears the end of the rows
(`search/grep-look` with `more`), and for the rows up to a match when Next Match or Previous Match goes beyond them
(`upto`; point goes to the row when it arrives).  A match more than 400 rows past the rows sent comes in a block
of rows around it after a gap row ("⋯ N more"), not with every row before it (one patch of 19,000 rows was over the
hub's 16 MiB per client, and it dropped the editor); when the gap row is in sight the view asks for the rows before it
(`fill`), and the gap row goes when they meet the block.  Replace All and the tick boxes read the model, so they act on every
match, not only the rows sent; the file watches follow the model's files too.

A text search is the hub's `search/run` (the view `search`, the fields' text and
toggles, the folder, or the file as the File scope, the include and exclude globs, the replacement, and the matches
unticked before it), and the results are the hub's rows, a
reset and then each file's header and matches, inserted below the fields by `drgnx-view-apply-patch`.  A new search
makes the hub send a reset and drop the old search's late rows, and the editor drops one that still arrives by its
base.  `search-run-done` ends the search and gives the count the status line shows; the status line shows
"Searching…" until then.  Typing in the Replace field is `search/grep-replace`: the hub patches the previews and
nothing is searched again.  Symbol mode (the language server's edits) keeps rows of Emacs's own (the `replace-results`
view type), and the view changes between the two with each search; `drgnx-view-old-path` has no Search path of its
own any more (plan sja-complete S2 removed the Lisp text engine).  The file watches stay Lisp: a listed file that changes on disk is searched again through the hub after half a second.  The hub reads the disk, so before each search, and half a second after an edit, the view sends it the text of each
buffer under the folder that has unsaved edits (`search/buffer`, only what changed since): the hub searches that text
in place of the file, also when the file on disk has no match, and the search shown takes it at once.  Those matches
are rows like any other, with tick boxes, in the model Next Match walks and Replace All writes.  A buffer over 4 MiB,
or open as a large file, is not sent: its file is searched on disk and its header says "open in chunks: searched on
disk".  A buffer saved or killed since is forgotten, and the hub reads its file again.
`test/unit/replace-rows-test.el` covers the stream with no hub.

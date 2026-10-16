# The workbench

drgnx's window model, VS Code style: editor windows in the middle, a left dock with the **Buffers** panel (open
files) above the **Explorer** (file tree), a **right dock** and a bottom **panel** (Terminal, Problems, Output,
Results, Help) — every buffer goes to its place by one rules table. Nothing moves on its own: a click lands where
you clicked, a row you selected stays selected, docks and panel keep their size. Popups, editor groups and several
windows arrive in the next milestones (see [roadmap.md](roadmap.md), M3).

Everything here is built on plain Emacs — no treemacs, no ibuffer — does what people use those for (and VS
Code's Explorer and Open Editors; see [Compared](#compared-with-treemacs-ibuffer-and-vs-code)), and does every
heavy operation 2–75× faster than they do; key presses are sub-millisecond in all three (see
[Performance](#performance)).

## Using it

| | VS Code keys | Emacs keys | Vim keys |
|---|---|---|---|
| Show / hide the sidebar | `C-b` | `<f8>` | `SPC e` |
| Focus the Explorer | `C-S-e` | `C-x M-e` | `SPC E` |
| Focus the Buffers panel | `C-k e` | `C-x C-b` | `SPC ,` |
| Back to the editor (in the sidebar) | `Escape` | `q` | `Escape` |
| Focus the editor | `C-1` | `C-x o` | `C-w` |

In the **Explorer**: a click on a folder opens or closes it; a click on a file opens it and keeps the Explorer
focused (so you can keep browsing); a double click on a file moves to the editor. Keys: up/down (`n`/`p` in the
Emacs profile, `j`/`k` in Vim), right expands or enters a folder, left collapses or goes to the parent, `RET`
opens (and focuses), `SPC` opens and stays (`g o` in Vim), `TAB` toggles a folder (Emacs), `g` / `R` refreshes.
Folders come first, names sort naturally (`file2` before `file10`) and case-insensitively; `.git` and other
clutter is hidden (`drgnx-explorer-exclude`). Dragging does nothing — the Explorer never moves files by drag.

When you switch files, the Explorer shows the new one — but never while you are using the Explorer (it is
selected, or a mouse button is down), never for a file outside its folder (opening another project's file does
not replace the tree), and without scrolling when the row is already visible. Showing the sidebar reveals the
file you are editing.

The **Buffers** panel lists open files in the order you opened them — switching never re-sorts it, so a row never
moves under the pointer. Each row: `×` closes, `●` marks unsaved changes, then the name and its folder; the file
in the active editor is in bold. Click a row to show it; `RET` too; `Delete` (`d`/`k` in Emacs, `x` in Vim) closes.

### Files

| | VS Code keys | Emacs keys | Vim keys |
|---|---|---|---|
| New file or folder (`a/b/c.txt` makes folders; end with `/` for a folder) | right-click | `+` | `a` |
| Rename (open buffers follow) | `F2` | `R` | `r` |
| Delete — to the trash, asks first | `Delete` | `D` | `d` |
| Delete permanently | `Shift+Delete` | `C-u D` | `D` |
| Copy / Cut / Paste (a taken name gets " copy" — never overwritten) | `C-c` / `C-x` / `C-v` | `M-w` / `C-w` / `C-y` | `y` / `x` / `p` |
| Copy path / relative path | `M-S-c` / `C-M-S-c` | `w` / `W` | `g y` / `Y` |
| Reveal in the file manager | `M-S-r` | `o x` | `s` |
| Select several: extend down / up, mark | `S-<down>` / `S-<up>`, `C-SPC` | `S-<down>` / `S-<up>`, `m` | `J` / `K`, `m` |
| Find (filter the tree) | `C-M-f` | `/` | `/` |

Ctrl-click adds a row to the selection, Shift-click selects a range; moving without Shift ends it. Delete, Copy,
Cut and Rename act on the selection. Every operation takes its targets before it asks anything, so nothing that
happens while you answer can make it act on another file. The right-click menu has the same entries.

**Typing** in the Explorer jumps to the next row starting with what you typed (letters a profile does not use).
**Find** filters the tree live to the files whose names contain the text — also inside collapsed folders — and the
title shows it; an empty text (or `C-g`) brings back the tree, its open folders, the view and the selection.

**Live**: files created, deleted or renamed outside Emacs appear within ~150 ms (only the changed folder is read
again; the view and selection stay; nothing changes while a mouse button is held).

**Git**: `M` modified, `A` added, `U` untracked, `R` renamed, `D` deleted, `C` conflict, in the colours of your
theme's version-control faces; a folder with changes inside shows `●`; ignored files are dimmed. One background
`git status` per repository (never holding your git lock); `drgnx-explorer-git` turns it off.

### Buffers panel

Save All (`C-k s` · palette — `C-x s` stays Emacs' asking save · `SPC f S`), Close Saved (`C-k u` · palette · `SPC b u`), Close All (`C-k C-w` · palette ·
`SPC b A`), Close Others (right-click · `o` · `O`), a live name filter (`C-M-f` · `/` · `/`), middle-click closes a
row, and "save all · close saved" buttons in the title. Git letters show after the names. The right-click menu has
Open, Close, Close Others and Save All.

All of these are commands in the palette and keys in every profile ([keys.md](keys.md)).

## Where buffers go

Every buffer Emacs shows goes to a **place** chosen by one rules table: files, dired and anything a rule sends
there go to the **editor** — a window already showing the buffer, else the selected editor, else the editor you
used last; never a new split, never a dock. Emacs' own window defaults are set so nothing splits or resizes on
its own (`split-height-threshold` and `split-width-threshold` nil, `even-window-sizes` nil,
`window-combination-resize` nil, `switch-to-buffer-obey-display-actions` t); `C-x 1` keeps the docks.

The table is one entry at the **end** of `display-buffer-alist`, so your own entries — and explicit actions such as
`display-buffer-overriding-action` — still win. Add or change a rule with `drgnx-wb-place`:

```elisp
(drgnx-wb-place 'my-log-mode 'editor)                 ; a major mode (derived modes too)
(drgnx-wb-place "\\`\\*my-tool\\*" 'current)         ; a buffer-name regexp
```

Later rules are tried first. A buffer no rule matches still goes to the editor, and is listed by **Show Unrouted
Buffers** (palette) — each one is a rule to add. Buffers whose names start with a space are internal and left
alone unless a rule names them.

| Place | What goes there |
|---|---|
| `editor` | files, dired, unmatched buffers (logged) |
| `current` | the selected window, unless it is a dock (then the editor) |
| `panel` Problems | flymake / flycheck lists |
| `panel` Output | `*Messages*`, `*Warnings*`, `*Backtrace*`, ert results |
| `panel` Results | compilation, grep, occur, xref |
| `panel` Terminal | shell, eshell, term, vterm, ielm, other comint buffers |
| `panel` Help | help, apropos, Info, man, eldoc documentation |
| `right` | agents, chat, viewers — tabs come with their modules (M7) |

### The panel and the right dock

The **panel** (Toggle Panel: ``C-` `` · palette · `SPC j`) sits under the editors; the **right dock** (Toggle
Right Dock: `C-M-b` · palette · `SPC R`) runs the frame's full height, like the left one. Each is one window with a
**tab row** at the top (click a tab to show it). Showing a buffer there never takes focus (Focus Panel does), and
switching tabs swaps the buffer *in place*: the window stays, nothing around it moves, and each tab comes back
scrolled where you left it. Both keep their pixel size across hiding and showing. Killing the buffer a tab shows
leaves the tab empty — another buffer never slips into the panel. `C-x 1` keeps the docks and the panel. The echo
area stays one line (`resize-mini-windows` is off), so a tall message never takes pixels from the panel.

## Compared with treemacs, ibuffer and VS Code

| | treemacs | ibuffer | VS Code | drgnx |
|---|---|---|---|---|
| Click model | double click opens | — | single click | single click; the tree never moves under the pointer |
| Drag | moves files, **no confirmation** | — | moves, confirms | never moves files |
| Git | colours, one process per folder | — | letters + colours | letters + colours, one background process per repository |
| Live updates | after 2 s | auto mode | yes | ~150 ms, view kept |
| Find | — | filters | filter in tree | live filter across collapsed folders, exact restore |
| File operations | yes (trash) | — | yes | yes (trash, never overwrites, targets fixed at start) |
| Multi-select | marks | marks | Ctrl/Shift | Ctrl/Shift click, Shift+arrows, mark |
| Open files order | — | by recency (rows move) | open order | open order (rows never move) |
| Bulk save/close | — | marked ops | Save All, Close Saved/All | Save All, Close Saved/Others/All |
| Speed | 49–668 ms | 45–74 ms | — | 0.6–88 ms |

Not yet: compact folders (`src/app` on one row — a cheap way to know a folder's only child is needed first),
file nesting, icons (an icon theme is a module, M4), problems decorations (with diagnostics, M5).

## How it works

- **The change bus** (`wb/drgnx-signal.el`) is the only code that listens to Emacs' window and buffer hooks. A
  hook only arms an idle flush; the flush compares the state with the previous one and emits **edges**:
  `editor-changed` (the file in the editor you used last), `buffer-set-changed`, `modified-changed`. Followers
  subscribe to these, never to hooks — so a focus change, a background buffer or a burst of events cannot make
  them fire. Internal buffers (names starting with a space) never count.
- **Roles** (`wb/drgnx-wb.el`): each window is an `editor` or a `dock` window (window parameter `drgnx-role`). The
  dock is side windows with a pixel width kept across hide/show, no scroll bars, and titles in the
  `header-line-format` *window parameter*, where no mode can erase them. Showing the dock never takes focus; files
  chosen in it go to the most recently used editor window, never splitting it. Sections are registered with
  `drgnx-wb-define-section` (slot, title, height, buffer, `:on-show`).
- **Explorer** (`wb/drgnx-explorer.el`) and **Buffers** (`wb/drgnx-buffers.el`) are **virtual lists**: the buffer
  holds plain text, inserted in one go; a vector holds what each line is (path, depth, folder or file — or the
  buffer); faces are painted by jit-lock for the rows on screen only. Expanding a folder inserts its rows after the
  folder's row; collapsing deletes them; nothing else is redrawn. Folder listings are cached while the folder is
  unchanged (one `directory-files-and-attributes` call per folder). The Buffers panel re-renders only when its rows
  changed and puts every window's view and selection back on the same buffers.

## Performance

`bin/drgnx test --bench` builds drgnx, makes a 25,000-file project (200 folders × 100 files, one 5,000-file
folder, a depth-8 file), and times the same operations with drgnx, treemacs and ibuffer in a GUI session — each
including a full redisplay; one-off operations are the median of 3, key presses the 95th percentile of 50.
Like for like: folder listings are read from disk in every run, the refreshed folder is open and the new files must
appear, the Buffers update includes drgnx's change bus, and the Buffers render creates the panel and its window as
ibuffer does.
The fixture is a git repository (everything committed, 50 files changed). Both run like-for-like: no file watching
(drgnx's live updates are held back), no follow, git off — then on for the two git rows and is loaded only in that session, from
`$DRGNX_BENCH_ELPA` (default `~/.config/emacs/elpa`); without it only drgnx and ibuffer are compared.

| Operation (ms) | drgnx | treemacs / ibuffer |
|---|---|---|
| First render of the project | 5.1 | 138.9 |
| … with git decorations (drgnx: the whole repository's status read and shown) | 88.0 | 152.6 |
| Expand the 5,000-file folder (read from disk) | 41.4 | 373.1 |
| … with git decorations | 41.6 | 397.0 |
| Reveal the depth-8 file | 1.8 | 49.0 |
| Refresh after 100 new files (shown) | 20.0 | 667.8 |
| Git status of the whole 25k-file repository (background) | 35.0 | — |
| Buffers panel, 500 buffers | 7.7 | 74.4 (ibuffer) |
| Buffers panel, one buffer added | 0.6 | 45.3 (ibuffer) |
| Key press (p95) | 0.6 / 0.8 | 0.2 / 2.1 |

(One machine, 2026-10; numbers vary, ratios hold.) The run fails if drgnx misses a budget (first render 30 ms,
expand 80, reveal 20, refresh 150, Buffers 30 / 15, keys 8) or is slower than the other tool by more than 0.5 ms
(the noise floor of sub-millisecond key timings). Batch tests also keep allocation in check: expanding 5,000 rows
must allocate under 3 MB — garbage is what makes a GUI session pause.

## Tests

Batch: `test/unit/wb-*-test.el` (bus, dock, Explorer, Buffers). GUI: `test/live/drgnx-workbench-test.el` (the dock
by real key presses: no focus taken, width identical over 10 hide/show cycles, titles, no scroll bars). Behaviour:
the ten Explorer and Buffers scenarios of [scenarios.md](scenarios.md), plus two for live updates (a folder
appearing during a held click; a folder appearing while browsing), are green on drgnx (`bin/drgnx test
--scenario --config drgnx`; driver `test/scenario/drivers/drgnx.el`).

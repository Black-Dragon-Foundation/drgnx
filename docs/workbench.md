# The workbench

drgnx's window model, VS Code style: editor windows in the middle, a left dock with the **Buffers** panel (open
files) above the **Explorer** (file tree). Nothing moves on its own: a click lands where you clicked, a row you
selected stays selected, the dock keeps its width. The rest of the workbench (right dock, bottom panel, popups,
editor groups, several windows) arrives in the next milestones (see [roadmap.md](roadmap.md), M3).

Everything here is built on plain Emacs — no treemacs, no ibuffer — and does every heavy operation 9–180×
faster than they do; key presses are sub-millisecond in all three (see [Performance](#performance)).

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

All of these are commands in the palette and keys in every profile ([keys.md](keys.md)).

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
treemacs runs like-for-like (no git status, no file watching, no follow) and is loaded only in that session,
from `$DRGNX_BENCH_ELPA` (default `~/.config/emacs/elpa`); without it only drgnx and ibuffer are compared.

| Operation (ms) | drgnx | treemacs / ibuffer |
|---|---|---|
| First render of the project | 5.4 | 121.3 |
| Expand the 5,000-file folder (read from disk) | 41.3 | 382.3 |
| Reveal the depth-8 file | 1.6 | 51.0 |
| Refresh after 100 new files (shown) | 23.6 | 721.6 |
| Buffers panel, 500 buffers | 6.5 | 76.1 (ibuffer) |
| Buffers panel, one buffer added | 0.4 | 70.9 (ibuffer) |
| Key press (p95) | 0.5 / 0.8 | 0.2 / 2.2 |

(One machine, 2026-10; numbers vary, ratios hold.) The run fails if drgnx misses a budget (first render 30 ms,
expand 80, reveal 20, refresh 150, Buffers 30 / 15, keys 8) or is slower than the other tool by more than 0.5 ms
(the noise floor of sub-millisecond key timings). Batch tests also keep allocation in check: expanding 5,000 rows
must allocate under 3 MB — garbage is what makes a GUI session pause.

## Tests

Batch: `test/unit/wb-*-test.el` (bus, dock, Explorer, Buffers). GUI: `test/live/drgnx-workbench-test.el` (the dock
by real key presses: no focus taken, width identical over 10 hide/show cycles, titles, no scroll bars). Behaviour:
the ten Explorer and Buffers scenarios of [scenarios.md](scenarios.md) are green on drgnx (`bin/drgnx test
--scenario --config drgnx`; driver `test/scenario/drivers/drgnx.el`).

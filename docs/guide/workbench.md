# The workbench

drgnx's window model, VS Code style: editor windows in the middle, a left dock with the **Buffers** panel (open
files) above the **Explorer** (file tree) and the **Outline**, a **right dock** and a bottom **panel** (Terminal, Problems, Output,
Results, Help) and a popup lane — every buffer goes to its place by one rules table. Nothing moves on its own: a
click lands where you clicked, a row you selected stays selected, docks and panel keep their size, popups leave no
trace. Editor groups split the editor, several windows each keep their own workbench, and the layout survives a
restart.

Everything here is built on plain Emacs — no treemacs, no ibuffer — does what people use those for (and VS
Code's Explorer and Open Editors; see [Compared](#compared-with-treemacs-ibuffer-and-vs-code)), and does every
heavy operation 2–150× faster than they do; key presses are under a millisecond (as fast as ibuffer, faster than
treemacs; see
[Performance](#performance)).

## Using it

| | VS Code keys | Emacs keys | Vim keys |
|---|---|---|---|
| Show / hide the sidebar | `C-b` | `<f8>` | `SPC e` |
| Focus the Explorer | `C-S-e` | `C-x M-e` | `SPC E` |
| Focus the Buffers panel | `C-k e` | `C-x C-b` | `SPC ,` |
| Back to the editor (in the sidebar) | `Escape` | `q` | `Escape` |
| Focus the editor (group 1) | `C-1` | `C-x o` | `C-w` |

In the **Explorer**: a click on a folder opens or closes it; a click on a file opens it and keeps the Explorer
focused (so you can keep browsing); a double click on a file moves to the editor. Keys: up/down (`n`/`p` in the
Emacs profile, `j`/`k` in Vim), right expands or enters a folder, left collapses or goes to the parent, `RET`
opens (and focuses), `SPC` opens and stays (`g o` in Vim), `TAB` toggles a folder (Emacs), `g` / `R` refreshes.
Folders come first, names sort naturally (`file2` before `file10`) and case-insensitively; `.git` and other
clutter is hidden (`drgnx-explorer-exclude`). Dragging does nothing — the Explorer never moves files by drag.

When you switch files, the Explorer shows the new one — but never while you are using the Explorer (it is
selected, or a mouse button is down), never for a file outside its folder (opening another project's file does
not replace the tree), never for a remote (TRAMP) file, and without scrolling when the row is already visible. Showing the sidebar reveals the
file you are editing.

The **Buffers** panel lists open files in the order you opened them — switching never re-sorts it, so a row never
moves under the pointer. Each row: `×` closes, `●` marks unsaved changes, then the name and its folder; the file
in the active editor is in bold. Click a row to show it; `RET` too; `Delete` (`d`/`k` in Emacs, `x` in Vim) closes.

### Outline

Below the Explorer, the **Outline** lists the definitions of the file in the editor (as imenu finds them, nested the
same way). A click shows the definition in the editor and keeps you in the Outline; `RET` goes there. It follows the
editor, and half a second after you stop typing, your edits — only while it is shown (hidden, it lets go of the file
at the next pause or editor change), and a key you press while it works wins (it tries again at the next pause). Files without an index, remote files and buffers over 1 MB get a
one-line notice instead. Focus Outline: palette · `SPC o`.

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
Open, Close, Close Others, Save All, and for the row's buffer Save, Copy Path, Diff with File and Reveal in Explorer.
The Explorer's right-click menu also has Reveal in Buffers, Open Folder in Dired and Open in Other Window.

Next Panel Tab (``M-` `` · palette) cycles the panel's tabs; Mode Menu (`C-'` · palette) opens the current major
mode's menu at the cursor, the menu-bar entry without the menu bar.

All of these are commands in the palette and keys in every profile ([keys.md](keys.md)).

## Where buffers go

Every buffer Emacs shows goes to a **place** chosen by one rules table: files, dired and anything a rule sends
there go to the **editor** — a window already showing the buffer, else the selected editor, else the editor you
used last; never a new split, never a dock. Emacs' own window defaults are set so nothing splits or resizes on
its own (`split-height-threshold` and `split-width-threshold` nil, `even-window-sizes` nil,
`window-combination-resize` nil, `switch-to-buffer-obey-display-actions` t); `C-x 1` keeps the docks.

The table is one entry at the **end** of `display-buffer-alist`, so your own entries and
`display-buffer-overriding-action` still win, and so does a caller that asks for a frame or for no window (`C-x 5 b`,
`display-buffer-no-window`). `C-x 4 b` shows the buffer in another editor when there is one; a window you locked with
`C-x w d` is left alone. Add or change a rule with `drgnx-wb-place`:

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
| `popup` | transient, which-key, `*Completions*`, `*Calendar*` |
| `other-group` | diffs and logs: another editor group (the one used last), else this one |

### Chrome

Every window's chrome is decided by its **role**, never by its buffer: an **editor** window has a tab line, a
breadcrumb header and a mode line; a **dock** section has its title only; the **panel** and the **right dock** have
their tab row only; a popup has none. The chrome lives in window parameters, so a mode that sets its own header or
mode line (ibuffer, Info) cannot change a window's height — text never jumps (invariant I3).

- **Tabs**: the buffers an editor window has shown, in the order they were opened; switching never reorders them.
  Click a tab to show it, `×` or middle-click closes it (the buffer stays open — close it in the Buffers panel).
  Close Tab `C-<f4>` · palette · `SPC b d`; Next / Previous Tab `C-<next>` / `C-<prior>` · Emacs' `C-x <right>` /
  `C-x <left>` · `SPC b n` / `SPC b p`. `*scratch*` is a tab only while it is shown. Killing a buffer takes its tab
  out of every window at once; a window that showed it shows the tab to its right, else its left.
- **Breadcrumb**: project › folders › file, `●` while unsaved. A buffer with a header line of its own (the column
  headings of a list, clicked to sort) keeps it.
- A buffer shown only for a moment — a preview while you choose in the minibuffer — does not become a tab.
- Popups in child frames (posframe, corfu, eldoc-box) keep their own look: they get no chrome.

### Editor groups

Split the editor into **groups** — each an editor window with its own tabs — only by command: Split Editor Right /
Down (``C-\`` / ``C-k C-\`` · Emacs' own `C-x 3` / `C-x 2` · `SPC w v` / `SPC w s`; the new group shows the same file),
Close Editor Group (palette · `C-x 0` · `SPC w c`; the last group stays), Close All Editors in Group (`C-k w`; the
palette in the Emacs and Vim profiles; its tabs go, the files stay open; the group closes, or, the last one, shows
`*scratch*`), Focus Group 1–3 (`C-1`–`C-3` · `C-x o` · `SPC 1`–`SPC 3`; one past the last makes a group to the right),
Move Editor into Next Group (`C-M-<right>` · palette · `SPC w m`; a group left without tabs closes, as in VS Code).
Groups are numbered left to right, top to bottom. Diffs and logs (`diff-mode`, `log-view-mode`, magit's diff and log)
open in the **other group** — the one you used last besides this one — never in a new split.

### The layout survives a restart

When Emacs exits, the workbench of every window is saved to `$XDG_STATE_HOME/drgnx/workbench.eld`
(`~/.local/state/…`) — with a daemon, when you close its last client (`C-x C-c`), every window of that client — and
the other windows are opened again at start (your window manager places them; the first one is the main window): the
left dock, the panel and its tab, the right dock — each with its pixel size — the editor groups with their sizes, tabs and
shown files, and the Explorer's folders. At the first graphical frame it comes back as it was
(`drgnx-persist-restore-on-start`) — with a daemon, in the first `emacsclient -c` frame; closing the last graphical
frame saves too. Each group's shown file opens at once and its other tabs open while you are idle; nothing asks
anything at start (no remote files are touched, only safe local variables, no large-file question). Files that no
longer exist are skipped, sizes are clamped to the frame, window parameters in the file are ignored (drgnx saves
none), and a state in another format is ignored. Save / Restore
Workbench Layout are in the palette. Only a graphical session saves — a batch run never writes your state.

### Several windows

Every frame (OS window) is its own workbench. The first one is the **main** window; windows opened later are
**editor-only** (no sidebar until you toggle one there). Move Editor into New Window, Open Editor in New Window
(``C-k o`` · palette · `SPC w o`; the file shows in both) and Move Editor Group into New Window (its tabs too) are in
the palette (Vim `SPC w n` / `SPC w g`). Each window has its **own buffers** — the tabs of its groups; the main window
also has the open files that are a tab nowhere — and the Buffers panel lists those of the window you work in;
Buffers: Show All Windows (palette · `SPC b a`) lists all. A help or results buffer shown from a window opens that
window's panel; nothing moves in the other window. drgnx never places or sizes a window: your window manager does.

### Popups

Short-lived buffers — a transient menu, which-key's hints, `*Completions*`, the calendar — show in one **popup
lane** and leave no trace. With the panel open, the popup borrows the panel's window: nothing around it moves, the
popup is not resized (longer content scrolls) — unless you are typing in the panel (a terminal): then the popup gets
a window beside it, so your input stays where it is. When it ends the panel's buffer, scroll, point, tab row and pixel
height come back exactly. With the panel hidden, the popup gets a window under the editors that is deleted when it
ends, giving every pixel back. However a package ends its popup — `delete-window`, `quit-window`, `bury-buffer`,
killing the buffer — the lane notices. A package that calls `display-buffer-in-side-window` directly (which-key does)
still goes where the rules say.

### The panel and the right dock

The **panel** (Toggle Panel: ``C-` `` · palette · `SPC j`) sits under the editors; the **right dock** (Toggle
Right Dock: `C-M-b` · palette · `SPC R`) runs the frame's full height, like the left one. Each is one window with a
**tab row** at the top (click a tab to show it). Showing a buffer there never takes focus (Focus Panel does), and
switching tabs swaps the buffer *in place*: the window stays, nothing around it moves, and each tab comes back
scrolled where you left it. Both keep their pixel size across hiding and showing. Killing the buffer a tab shows
leaves the tab empty — another buffer never slips into the panel. `C-x 1` keeps the docks and the panel; `C-x 0` in
the panel hides it (size and tabs kept). The echo
area stays one line (`resize-mini-windows` is off), so a tall message never takes pixels from the panel; while you
type in the minibuffer it may grow (icomplete-vertical, fido-vertical).

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
| Speed | 50–636 ms | 74–78 ms | — | 0.5–89 ms |

Not yet: compact folders (`src/app` on one row — a cheap way to know a folder's only child is needed first),
file nesting, icons (an icon theme is a module, M4), problems decorations (with diagnostics, M5).

## How it works

- **The change bus** (`wb/drgnx-signal.el`) is the only code that listens to Emacs' window and buffer hooks. A
  hook only arms an idle flush; the flush compares the state with the previous one and emits **edges**:
  `editor-changed` (the file in the editor you used last), `buffer-set-changed`, `modified-changed`. Followers
  subscribe to these, never to hooks — so a focus change, a background buffer or a burst of events cannot make
  them fire. Internal buffers (names starting with a space) never count. A follower (or a window-setup function)
  that fails is recorded in `drgnx-signal-errors`; the others still run and the next flush stays armed.
- **Roles** (`wb/drgnx-wb.el`): each window is an `editor` or a `dock` window (window parameter `drgnx-role`). The
  dock is side windows with a pixel width kept across hide/show, no scroll bars, and titles in the
  `header-line-format` *window parameter*, where no mode can erase them. Showing the dock never takes focus; files
  chosen in it go to the most recently used editor window, never splitting it. Sections are registered with
  `drgnx-wb-define-section` (slot, title, height, buffer, `:on-show`). The dock's buffers are internal (` *drgnx
  explorer*`, ` *drgnx buffers*`, ` *drgnx outline*` — a leading space), so `C-x b` and ibuffer never list them.
- **Owned windows.** Code running from a timer or a follower may move only windows that show its own buffer, and
  says so with `drgnx-wb-with-owned-windows`; the harness's jank guard records any other window move made from a
  timer (invariant I9).
- **Explorer** (`wb/drgnx-explorer.el`) and **Buffers** (`wb/drgnx-buffers.el`) are **virtual lists**: the buffer
  holds plain text, inserted in one go; a vector holds what each line is (path, depth, folder or file — or the
  buffer); faces are painted by jit-lock for the rows on screen only. Expanding a folder inserts its rows after the
  folder's row; collapsing deletes them; nothing else is redrawn. Folder listings are cached while the folder is
  unchanged (one `directory-files-and-attributes` call per folder). The Buffers panel re-renders only when its rows
  changed and puts every window's view and selection back on the same buffers.

## Performance

`bin/drgnx test --bench` builds drgnx, makes a 25,000-file project (200 folders × 100 files, one 5,000-file
folder, a depth-8 file), and times the same operations with drgnx, treemacs and ibuffer in a GUI session — each
including a full redisplay; one-off operations are the median of 3, key presses the 95th percentile of 300 (50 left the result to the third-slowest press).
Like for like: folder listings are read from disk in every run, the refreshed folder is open and the new files must
appear, the Buffers update includes drgnx's change bus, and the Buffers render creates the panel and its window as
ibuffer does.
The fixture is a git repository (everything committed, 50 files changed). Both run like-for-like: no file watching
(drgnx's live updates are held back), no follow, git off — then on for the two git rows and is loaded only in that session, from
`$DRGNX_BENCH_ELPA` (default `~/.config/emacs/elpa`); without it only drgnx and ibuffer are compared.

| Operation (ms) | drgnx | treemacs / ibuffer |
|---|---|---|
| First render of the project | 5.1 | 146.5 |
| … with git decorations (drgnx: the whole repository's status read and shown) | 88.8 | 151.3 |
| Expand the 5,000-file folder (read from disk) | 36.3 | 317.3 |
| … with git decorations | 39.4 | 388.8 |
| Reveal the depth-8 file | 1.9 | 50.1 |
| Refresh after 100 new files (shown) | 19.7 | 636.4 |
| Git status of the whole 25k-file repository (background) | 32.1 | — |
| Buffers panel, 500 buffers | 9.1 | 78.0 (ibuffer) |
| Buffers panel, one buffer added | 0.5 | 74.0 (ibuffer) |
| Key press (p95: Explorer / Buffers) | 0.5 / 0.9 | 3.5 / 0.8 |

(One machine, 2026-10; numbers vary, ratios hold.) The run fails if drgnx misses a budget (first render 30 ms,
expand 80, reveal 20, refresh 150, Buffers 30 / 15, keys 8) or is slower than the other tool by more than 0.5 ms
(the noise floor of sub-millisecond key timings); key presses run in the same frame for each tool. Batch tests also keep allocation in check: expanding 5,000 rows
must allocate under 3 MB — garbage is what makes a GUI session pause.

## Invariants

What "nothing moves on its own" means, each pinned by a test in a GUI session with the jank guard on
(`bin/drgnx test --ui`; `test/live/drgnx-invariants-test.el` unless named):

| | Invariant | Test |
|---|---|---|
| I1 | No collateral move: a step changes only the windows it aims at | `drgnx-inv/i1-i9-i10-explorer-and-buffers-flows`, the scenarios |
| I2 | Docks and panel keep their pixel size across hide/show, tab switches, popups and a restart | `drgnx-inv/i2-every-area-keeps-its-size`, `drgnx-inv/i2-sizes-survive-a-restart` |
| I3 | Chrome height depends on the window's role only | `drgnx-inv/i3-chrome-height-depends-on-the-role-only`, `test/unit/wb-chrome-test.el` |
| I4 | Frame rows constant; the echo area stays one line | `drgnx-inv/i4-buffer-switches-and-messages-keep-the-rows` |
| I5 | Popups leave no trace | `drgnx-inv/i5-which-key-leaves-no-trace`, `test/live/drgnx-popup-test.el` |
| I6 | Followers react to edges, never to focus alone | `test/unit/wb-signal-test.el` |
| I7 | Panels refresh only when their rows changed and keep the view by identity | `test/unit/wb-buffers-test.el` |
| I8 | 50 commands that display buffers: no split, no resize, no frame, nothing unrouted | `drgnx-inv/i8-fuzz-of-fifty-commands` (`test/fixtures/fuzz-commands.eld`) |
| I9 | No window moved from a timer except the caller's own | every report's `guard_violations` = 0 |
| I10 | Each step settles within 250 ms, without oscillation | `drgnx-inv/i1-i9-i10-explorer-and-buffers-flows` |

Two Emacs behaviours the workbench corrects so that these hold: `balance-windows` on a whole frame (finder calls
it) balances only the editors, and a package calling `display-buffer-in-side-window` directly still gets the place
its buffer's rule names.

## Tests

Batch: `test/unit/wb-*-test.el` (bus, dock, Explorer, Buffers). GUI: `test/live/drgnx-workbench-test.el` (the dock
by real key presses: no focus taken, width identical over 10 hide/show cycles, titles, no scroll bars). Behaviour:
the ten Explorer and Buffers scenarios of [scenarios.md](../develop/scenarios.md), plus two for live updates (a folder
appearing during a held click; a folder appearing while browsing), are green on drgnx (`bin/drgnx test
--scenario --config drgnx`; driver `test/scenario/drivers/drgnx.el`).

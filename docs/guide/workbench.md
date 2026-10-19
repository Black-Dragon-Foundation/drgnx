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
| Focus the Explorer | palette | `C-x M-e` | `SPC E` |
| View: Explorer / View: Search (swap the sidebar's view) | `C-S-e` / `C-S-f` | palette | palette / `SPC /` |
| Focus the Buffers panel | `C-k e` | `C-x C-b` | `SPC ,` |
| Back to the editor (in the sidebar) | `Escape` | `q` | `Escape` |
| Focus the editor (group 1) | `C-1` | `C-x o` | `C-w` |

The sidebar has **views**, like VS Code's activity bar: **View: Explorer** shows the Buffers panel, the Explorer
and the Outline; **View: Search** shows the Search view. The two commands show their view and move focus to it (the Explorer's
file tree, the Search view with the cursor in its Find field), like VS Code's `Ctrl+Shift+E` and `Ctrl+Shift+F`.
Focus Explorer, Focus Outline and the like also switch the sidebar to their view first. The Search view is set up the
first time it is asked for, also in the first second after a start (its module sets up once Emacs is idle). Swapping the view another way
(`drgnx-wb-show-view`, as a layout does; there are no clickable view tabs yet) swaps the sections in place, at the same width, and leaves focus where it was (a focus inside the
sidebar moves to the new view's first section); with the sidebar hidden it shows it. Hiding and showing the sidebar brings back the view it had.

**Turning a module off** hides its panes (a panel tab, a right-dock tab) and removes its sections and tabs; nothing
else in the workbench moves. The size you gave a pane and its place in front are remembered: turn the module on again
and the pane comes back at that size, and shows at once when its panel or dock is open with it in front.

In the **Explorer**: a click on a folder opens or closes it; a click on a file opens it and keeps the Explorer
focused (so you can keep browsing); a double click on a file moves to the editor. Keys: up/down (`n`/`p` in the
Emacs profile, `j`/`k` in Vim), right expands or enters a folder, left collapses or goes to the parent, `RET`
opens (and focuses), `SPC` opens and stays (`g o` in Vim), `TAB` toggles a folder (Emacs), `g` / `R` refreshes.
Folders come first, names sort naturally (`file2` before `file10`) and case-insensitively; `.git` and other
clutter is hidden (`drgnx-explorer-exclude`). Dragging does nothing — the Explorer never moves files by drag.

**Compact folders:** an open folder whose only entry is a folder shares its row (`src/app`), as in VS Code; the row
is the last folder (opening, renaming, deleting act on it) and the chain ends at the first closed folder. Only
listings the Explorer has read anyway are used — a closed folder is never read to see whether it could join, so the
joining happens when you open it (the row then grows, `src` → `src/app`) and again whenever a folder in the chain
changes (a second entry splits the row). The folders in the middle of a row are watched too. Turn it off with
`drgnx-explorer-compact-folders`. Typing a prefix matches the row as shown.

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
one-line notice instead. The definition your cursor is in is highlighted in the Outline (an overlay, set a moment
after the cursor stops — the Outline's own cursor is yours and never moves). An edit that only moves definitions redraws
nothing, and the Outline keeps your place in it when definitions are added above. Focus Outline: palette · `SPC o`.

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

Ctrl-click adds a row to the selection, Shift-click selects a range (in a terminal window Shift-click is the
terminal's own, so a range is Shift+arrows there); moving without Shift ends it. Delete, Copy,
Cut and Rename act on the selection; a folder selected together with something inside it counts once (the folder
carries it). Every operation takes its targets before it asks anything, so nothing that happens while you answer
can make it act on another file, and Paste checks every item before it moves the first. Deleting a symbolic link
removes the link, never what it points to. Deleting a file closes the buffers visiting it (a folder: the ones
inside it); a buffer with unsaved changes stays, and a message says so. When the trash is on another device
than the file (Emacs would copy it across, and wait), `gio trash` does it in the background if `gio` is
installed and you have not set `trash-directory` (gio ignores it). The buffers close, and a message about an
unsaved one appears, only when the file is really gone. If gio refuses (tmpfs and other internal mounts), the
file goes to the trash the Emacs way instead; only if that fails too does the echo area say so, with gio's
reason. The folder is refreshed when it ends (a folder you collapsed meanwhile stays collapsed). New File and Rename stay inside the Explorer's folders (`../x`, `~/x`
and absolute paths are refused); the new file's row is shown, its new folders opened. A rename that changes only
the case works on case-insensitive disks too. Reveal in the file manager uses `xdg-open` on Linux, `open -R`
on macOS and `explorer.exe /select,` on Windows; it refuses a remote (TRAMP) path. Remote folders are listed
but never watched for changes (a remote watch starts a process that blocks); refresh them by hand. The right-click menu has the same entries.

**Typing** in the Explorer jumps to the next row starting with what you typed (letters a profile does not use).
**Find** filters the tree live to the files whose names contain the text — also inside collapsed folders — and the
title shows it; an empty text (or `C-g`) brings back the tree, its open folders, the view and the selection.

**Live**: files created, deleted or renamed outside Emacs appear within ~150 ms (only the changed folder is read
again; the view and selection stay; nothing changes while a mouse button is held — a press whose release never
reaches the Explorer, because Emacs lost focus or the release came with a modifier or in another window, ends
there).

**Git**: `M` modified, `A` added, `U` untracked, `R` renamed, `D` deleted, `C` conflict, in the colours of your
theme's version-control faces; a folder with changes inside shows `●` (also one whose only change is a new file;
a new folder itself shows `U`), and so does a root; ignored files are dimmed. One background `git status` per
repository (never holding your git lock), repositories nested inside the tree included; a repository made after
the tree was shown (`git init`) is picked up at the next refresh (a save, or Emacs getting the focus back).
The status of at most 16 repositories is kept; one that was pushed out is read again by the next refresh of its
folder. `drgnx-explorer-git` turns it off. What git complains
about is kept in the hidden buffer ` *drgnx git errors*` (its last `drgnx-git-errors-max` characters).

### Buffers panel

Save All (`C-k s` · palette — `C-x s` stays Emacs' asking save · `SPC f S`), Close Saved (`C-k u` · palette · `SPC b u`), Close All (`C-k C-w` · palette ·
`SPC b A`), Close Others (right-click · `o` · `O`) — the three close only rows shown, never buffers the filter
hides —, a live name filter (`C-M-f` · `/` · `/`), middle-click closes a
row, and "save all · close saved" buttons in the title. Git letters show after the names. The right-click menu has
Open, Close, Close Others, Save All, and for the row's buffer Save, Copy Path, Diff with File and Reveal in Explorer.
The Explorer's right-click menu also has Reveal in Buffers, Open Folder in Dired and Open in Other Window.

Next Panel Tab (``M-` `` · palette) cycles the panel's tabs; Mode Menu (`C-'` · palette) opens the current major
mode's menu at the cursor, the menu-bar entry without the menu bar.

All of these are commands in the palette and keys in every profile ([keys.md](keys.md)).

### Panels with Vim keys

With the Vim profile (modal editing on, [keys.md](keys.md)) the editors are in Vim's normal state, but every panel is
in **Emacs state**: the Explorer, Buffers, Outline, Work, Agents, Diff, Review, Pull Requests, Welcome and Modules
views, and the other lists and transcripts. Vim's own keys do not reach them, so a panel keeps its own letters.

- **Rows.** `j` / `k` move down and up one row in every panel (the Explorer's own `j` / `k` and arrows do the same);
  `h` / `l` collapse and expand in the Explorer.
- **The leader and windows.** `SPC …` (`SPC f f`, `SPC SPC`) and `C-w h` / `j` / `k` / `l` work in a panel as in an
  editor, so you can leave a panel by key.
- **Escape.** `<escape>` in the sidebar (Explorer, Buffers, Outline) goes back to the editor, as Back to the Editor
  does, in every key profile. The right dock (Work, Agents) has no Escape: `C-w l` reaches it and `C-w h` comes back.
- **Refresh.** `g` refreshes the Diff, Review and Pull Requests views, as without Vim keys.
- **Search and type-ahead.** `/` filters the Explorer and Buffers panel (the text you type is the minibuffer's, so
  `SPC` types a space). A letter that nothing binds in the Explorer, the panel keys or the leader jumps to the next
  row starting with it.
- **No cursor box.** A panel shows no text cursor in any state, whatever state the engine passes through.

## Where buffers go

Every buffer Emacs shows goes to a **place** chosen by one rules table: files, dired and anything a rule sends
there go to the **editor** — a window already showing the buffer, else the selected editor, else the editor you
used last; never a new split, never a dock. Emacs' own window defaults are set so nothing splits or resizes on
its own (`split-height-threshold` and `split-width-threshold` nil, `even-window-sizes` nil,
`window-combination-resize` nil, `switch-to-buffer-obey-display-actions` t); `C-x 1` keeps the docks.

The table is one entry at the **end** of `display-buffer-alist`, so your own entries and
`display-buffer-overriding-action` still win, and so does a caller that asks for a frame or for no window (`C-x 5 b`,
`display-buffer-no-window`). `C-x 4 b` shows the buffer in another editor when there is one; a window you locked with
`C-x w d` is left alone. If your configuration replaces the variable after drgnx started (`(setq display-buffer-alist …)`
instead of `add-to-list`), drgnx's entry is gone and buffers go wherever Emacs puts them: every start writes
`wb-report.eld` (in `~/.local/state/drgnx/`) once init is done, and `drgnx doctor` (`display-rules`) warns when the
entry is missing. Add or change a rule with `drgnx-wb-place`:

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
mode line (ibuffer, Info) cannot change a window's height — text never jumps (invariant I3). A terminal window
needs at least 30 frame lines for the breadcrumb row, which is 31 terminal rows with the menu bar on (the menu bar
is not a frame line); with fewer, the frame parameter `drgnx-chrome-breadcrumb` is `off` (set by the terminal layout)
and the row is gone, sticky scroll's scopes with it. It comes back with room, and a buffer's own header line (column
headings) stays.

- **Tabs**: the buffers an editor window has shown, in the order they were opened; switching never reorders them.
  Click a tab to show it, `×` or middle-click closes it (the buffer stays open — close it in the Buffers panel).
  Close Tab `C-<f4>` · palette · `SPC b d`; Next / Previous Tab `C-<next>` / `C-<prior>` · Emacs' `C-x <right>` /
  `C-x <left>` · `SPC b n` / `SPC b p`. `*scratch*` is a tab only while it is shown. Killing a buffer takes its tab
  out of every window at once; closing the shown tab (or killing its buffer) shows the tab you used before it, as in VS Code; with no such tab, the one to its right, else its left. Each window keeps its own history.
- **Breadcrumb**: project › folders › file, `●` while unsaved. A buffer with a header line of its own (the column
  headings of a list, clicked to sort) keeps it.
- **At once**: chrome follows the workbench state store, so it is in place before a frame is drawn. A window made by
  anything — a split, a popup, a timer — has its tab line and header at the first redraw; `C-x o` between two windows
  showing one buffer moves the tabs and the breadcrumb on the spot. Saving or reverting a buffer updates its `●` a
  moment later.
- A buffer shown only for a moment — a preview while you choose in the minibuffer — does not become a tab.
- Popups in child frames (posframe, corfu, eldoc-box) keep their own look: they get no chrome.

### Editor groups

Split the editor into **groups** — each an editor window with its own tabs — only by command: Split Editor Right /
Down (``C-\`` / ``C-k C-\`` · Emacs' own `C-x 3` / `C-x 2` · `SPC w v` / `SPC w s`; the new group shows the same file),
Close Editor Group (palette · `C-x 0` · `SPC w c`; the last group stays), Close All Editors in Group (`C-k w`; the
palette in the Emacs and Vim profiles; its tabs go, the files stay open; the group closes, or, the last one, shows
`*scratch*`), Focus Group 1–3 (`C-1`–`C-3` · `C-x o` · `SPC 1`–`SPC 3`; one past the last makes a group to the right),
Move Editor into Next Group (`C-M-<right>` · palette · `SPC w m`; a group left without tabs closes, as in VS Code),
Focus Left / Right / Above / Below (palette · palette · `C-w h` / `l` / `k` / `j`: the group or dock next to this window
in that direction, docks included; at an edge nothing happens).
Groups are numbered left to right, top to bottom. Diffs and logs (`diff-mode`, `log-view-mode`, magit's diff and log)
open in the **other group** — the one you used last besides this one — never in a new split.

### The layout survives a restart

When Emacs exits, the workbench of every window is saved to `$XDG_STATE_HOME/drgnx/workbench.eld`
(`~/.local/state/…`) — with a daemon, when you close its last client (`C-x C-c`), every window of that client — and
the other windows are opened again at start (your window manager places them; the one saved as the main window goes
into the frame you start in, the others follow in order): the left dock (and the sidebar view it shows, Explorer or
Search), the panel and its tab, the right dock — each with its pixel size — the layout you were in
([layouts.md](layouts.md#after-a-restart)), the editor groups with their sizes, tabs and shown files, and the
Explorer's folders. A window that rebuilds itself comes back where and how big it was (only where a monitor still is; never bigger than its screen).
A job window saved before M12f comes back as the Work cockpit's filter on that job: no frame of its own, and the
restored panes, sizes and focus stay as they were ([jobs.md](jobs.md#a-job-in-the-work-cockpit)).

At the first graphical frame it comes back as it was (`drgnx-persist-restore-on-start`) — with a daemon, in the first
`emacsclient -c` frame, once the server has shown its `*scratch*` there (the restored files replace it); closing the
last graphical frame saves too (a child frame, such as a popup, does not count as a window). It also comes back
**whenever a window opens after none**: a daemon that keeps running after its last window closed
([opening.md](opening.md#keep-running-or-quit)) gives the next `drgnx open` or `emacsclient -c` the saved layout again
(a second window opened while one is already open is never restored over; a frame is restored once, and one whose
restore failed is not tried again). A file that client asked for is shown in front afterwards (the server switches to
it after the restore); add a function to `drgnx-persist-after-restore-functions` (called with the restored frame, after
every restore, never prompting; the other windows of a saved workbench are not passed to it) to do something of your
own at that moment. To keep data of your own in the saved state, add a function to `drgnx-persist-state-functions`
that returns a plist of namespaced keys (`:mymodule-thing`) with plain values only (symbols, numbers, strings, lists, vectors; text properties of strings are dropped); one that
returns anything else (a buffer, a hash table, a record) is left out (said once) without costing the other functions'
keys or the save.

Each group's shown file opens at once and its other tabs open while you are idle, all within the first pause (typing
stops them until your next pause, which carries on with the rest); nothing asks anything at start (no
remote files are touched, only safe local variables, no large-file question). Files that no longer exist are skipped,
sizes are clamped to the frame, window parameters in the file are ignored (drgnx saves none), and a state in another
format is ignored. The file is written whole and atomically (a crash or a full disk leaves the last saved layout), and
read with limits (4 MiB, no deep nesting, plain data only). A file written by a **newer drgnx** is never overwritten:
the save says "workbench.eld was written by a newer drgnx: not saved" and stops, and the restore ignores it. A file
that cannot be read (a typing mistake, a crafted file) is not restored, one message says so, and the next save keeps a
copy of it beside the file (`workbench.eld.bak-…`, the newest three) before writing the new layout. A save that fails
at exit (another Emacs holds the file for more than a second, the disk is full) is one message, never an error.
Save / Restore Workbench Layout are in the palette. Only graphical windows save and restore — a
batch run never writes your state.

Which windows are saved is what the workbench state store says: its visible graphical frames, the main window first
(a terminal window and a child frame are never saved). **The sizes saved are the ones you chose**: a dock or the
panel is saved at the size you set (by dragging it, or by a restore), not at the one a popup, the window manager or a
layout squeezed it to; a pane you never sized is saved at the size it has. The panel is saved at its own size even
while a popup borrows its window. A restore writes the sizes and the sidebar view back as chosen, so they win over a
size you set earlier in this session. The file format is the same as before; files saved by earlier versions restore
as they did. Restore Workbench Layout typed in a terminal window, while a graphical window is open, restores into
that window and says so in the echo area; with none open, it says layouts belong to graphical windows.

**Terminal windows** (`emacs -nw`, `emacsclient -t`) open with the default layout for their size
([terminal.md](terminal.md)) and neither save nor restore their own layout: a terminal session never overwrites the
layout of your desktop windows. Save Workbench Layout, run in a terminal window, does nothing and says "Layouts are
saved and restored from graphical windows". Restore Workbench Layout, run in a terminal window while a graphical
window is open, restores the saved layout into that graphical window (not into the terminal) and says "Restored into
the graphical window"; focus stays in the terminal (you may be over SSH). With no graphical window open, it does nothing and gives the same message as Save. A job window
comes back on the graphical display only, never laid out over a terminal window; with no graphical window, it is not
restored.

**Monitors.** Each window also remembers the monitor it was on (its make, model, serial, name and place, and whether it
was full screen or maximized), and the other windows go back to it after a restart, on the window managers that let
drgnx move a window (see [Several monitors](#several-windows)). Where Emacs itself knows only a window's place (on
Wayland), drgnx asks the window manager which of its monitors is there, so the serial and name are what is
remembered; after a move it keeps the monitor it moved the window to. The monitor is found by its serial, else its
name, else its place, never by the number it had; if it is not connected any more, the window stays where your window
manager opened it and drgnx says so in one message ("1 window's monitor is not connected (DELL U2720Q); the window
manager placed it"). The main window, windows opened for `$EDITOR` (terminal and EDITOR frames) and job windows are never moved. This happens after the
layout is back, in the background, with a few seconds' limit: a window manager that does not answer costs nothing but
one message. Where drgnx cannot tell which monitor a window is on (GNOME, other Wayland compositors, a terminal) nothing is
saved and nothing is moved.

### Several windows

Every frame (OS window) is its own workbench. The first one is the **main** window; windows opened later are
**editor-only** (no sidebar until you toggle one there). Move Editor into New Window, Open Editor in New Window
(``C-k o`` · palette · `SPC w o`; the file shows in both) and Move Editor Group into New Window (its tabs too) are in
the palette (Vim `SPC w n` / `SPC w g`). Each window has its **own buffers** — the tabs of its groups; the main window
also has the open files that are a tab nowhere — and the Buffers panel lists those of the window you work in;
Buffers: Show All Windows (palette · `SPC b a`) lists all. `C-x b` lists the buffers of the window you work in
first and every other buffer after them: it sorts, it never hides one (the order is set on the `buffer` completion
category, in `completion-category-overrides`; a `display-sort-function` of your own there stays). A help or results buffer shown from a window opens that
window's panel; nothing moves in the other window. **drgnx moves a window only when you ask or on restore, and never sizes one**: the three commands below move the window you are in, and a restore puts each extra window back on its monitor ([the layout survives a restart](#the-layout-survives-a-restart)); the main window, other apps' windows and every size stay with your window manager.

**Several monitors.** Move to Monitor… (palette · the window's right-click menu, shown only when more than one
monitor is known), Move to Next Monitor and Move to Previous Monitor (palette; they wrap round) move the window you
are in to another monitor. The picker lists the monitors as the window manager names them, numbered left to right:
`2 — DP-2, 2560×1440, right of 1`. A command never waits for the window manager (the picker alone waits,
for the list, a few seconds at most): it says "Moving…" and then "Moved to monitor 2 (DP-2)", or why it could not, in the echo area. The
commands exist only in graphical windows and work on sway, i3, Hyprland, niri, KWin and plain X11 or macOS; on GNOME
(which does not let apps move their windows) and on other Wayland compositors they say so and name the key that does
(on GNOME, Super+Shift+→ or ←). A window manager moves only the window that has focus, so a move is refused with a
plain message while another app has it. None of the three has a key by default (`:none` in every profile): bind them
in your key profile or use the palette.

**What each window manager allows.** drgnx finds the window manager from the window's own environment (one drgnx
can serve windows on several desktops). `drgnx doctor` shows the row for yours ([install.md](install.md#drgnx-doctor)).
*Verified* means a test tier runs it against the real program; *reported* means it was written from the program's
documentation and recorded replies and has not run here yet.

| Window manager | Found by | Move to Monitor, restore | Status |
|---|---|---|---|
| sway | `SWAYSOCK` | yes (`swaymsg`): the window you are in, while it has focus; restore by window | verified (sway tier) |
| i3 | `I3SOCK`, or the root window's `I3_SOCKET_PATH` | yes (`i3-msg`) | verified (i3 tier) |
| Hyprland | `HYPRLAND_INSTANCE_SIGNATURE` | yes (`hyprctl`) | reported |
| niri | `NIRI_SOCKET` | yes (`niri msg`); a restore warps the pointer to the target output (niri cannot be told not to) | reported (the container runs it with one output only) |
| KDE Plasma 6 (KWin) | `XDG_CURRENT_DESKTOP` lists KDE | yes (KWin's scripting over D-Bus) | verified (KWin in the container) |
| plain X11 (another X window manager) | `DISPLAY` without `WAYLAND_DISPLAY` | yes, by frame position | verified (x11 tier) |
| macOS | a Cocoa window | yes, by frame position | reported (not run by a tier yet) |
| GNOME (Mutter) | `XDG_CURRENT_DESKTOP` lists GNOME | no: GNOME does not let apps move windows; the commands say so — press **Super+Shift+→** or **Super+Shift+←** (GNOME's "Move window one monitor to the right/left"); a restore leaves placement to GNOME | GNOME's message unit-tested; the mutter tier verifies the other-Wayland path (it sets no `XDG_CURRENT_DESKTOP`): the command refuses, names the compositor's own key, moves nothing |
| another Wayland compositor (river, Wayfire, labwc, Cosmic…) | `WAYLAND_DISPLAY` and none of the above | no: the commands say so and point to its own key | — |

**Floating drgnx's windows.** A tiling window manager tiles drgnx's extra windows like any other. If you want them
floating, tell your window manager; drgnx writes no rules for it. The app id (Wayland) or class is the Emacs
program's name (`emacs`, or `emacs-pgtk` for that build) and the title starts with the buffer's name, as Emacs sets it (`frame-title-format`); a
rule by title matches whichever window shows that buffer. For example, every Emacs window floating, or only the
windows showing a Markdown file:

```
# sway (~/.config/sway/config)
for_window [app_id="^emacs"] floating enable
for_window [app_id="^emacs" title="\.md"] floating enable

# Hyprland (hyprland.conf)
windowrulev2 = float, class:^(emacs.*)$
windowrulev2 = float, class:^(emacs.*)$, title:.*\.md.*
```

**In a terminal.** A terminal window — `emacsclient -t`, `emacs -nw` — is a workbench window too: the same docks,
groups, tab line, breadcrumb, panel and status bar, and the first one is the main window (a daemon's own hidden
frame never is) until the daemon's first graphical window opens, which then becomes the main window. A client that asked for a file (`emacsclient -t FILE`, git's `EDITOR`) shows the editor only and
returns when you close the file's tab or press `C-x #`. See [terminal.md](terminal.md).

**In a small terminal.** A new terminal window shows the sidebar from 120 columns and the panel from 30 lines; the
docks are fractions of the terminal (a quarter of the columns for the sidebar, 30% of the lines for the panel) and
follow its size. They come when it grows (unless you toggled them), never close when it shrinks, and below 40x12
nothing is shown or resized. See [Small terminals](terminal.md#small-terminals).

### Popups

Short-lived buffers — a transient menu, which-key's hints, `*Completions*`, the calendar — show in one **popup
lane** and leave no trace. With the panel open, the popup borrows the panel's window: nothing around it moves, the
popup is not resized (longer content scrolls) — unless you are typing in the panel (a terminal): then the popup gets
a window beside it, so your input stays where it is. When it ends the panel's buffer, scroll, point, tab row and pixel
height come back exactly. With the panel hidden, the popup gets a window under the editors that is deleted when it
ends, giving every pixel back. However a package ends its popup — `delete-window`, `quit-window`, `bury-buffer`,
killing the buffer — the lane notices. A package that calls `display-buffer-in-side-window` directly (which-key does)
still goes where the rules say.

The lane always has a one-line header: the popup's name (`Calendar`, `which-key`) and a **×** at the right end —
click it, or press `Esc` or `q` while the lane has focus (**Close Pane**), to end the popup. Because the header is
there whether the popup borrows the panel or has a window of its own, borrowing never changes the header's height.

In a terminal window the lane works the same, and the line you are on stays visible. On Emacs 30.2 completion as you
type (corfu) also shows there, as `*Completions*`; on 31.1 corfu's popup is a child frame. See
[terminal.md](terminal.md#popups).

### The panel and the right dock

The **panel** (Toggle Panel: ``C-` `` · palette · `SPC j`) sits under the editors; the **right dock** (Toggle
Right Dock: `C-M-b` · palette · `SPC R`) runs the frame's full height, like the left one. Each is one window with a
**tab row** at the top (click a tab to show it). Showing a buffer there never takes focus (Focus Panel does), and
switching tabs swaps the buffer *in place*: the window stays, nothing around it moves, and each tab comes back
scrolled where you left it. Both keep their pixel size across hiding and showing. **The size you chose stays:**
a size you set for the left dock, the panel or the right dock is the one it comes back at the next time it shows.
A popup that squeezes the panel, the window manager shrinking the window or a layout applied later does not
replace it. A dock you drag to a new width (or a panel to a new height) keeps that size when the frame is resized. Killing the buffer a tab shows
leaves the tab empty — another buffer never slips into the panel. `C-x 1` keeps the docks and the panel; `C-x 0` in
the panel hides it (size and tabs kept), and so does `q` in a panel buffer that binds it to quit (Help, Info, a
compilation, …): the panel hides and focus goes back to the editor, as Escape does in VS Code. The echo
area stays one line (`resize-mini-windows` is off), so a tall message never takes pixels from the panel; while you
type in the minibuffer it may grow (icomplete-vertical, fido-vertical).

**Closing.** Every help pane, popup and side pane has a **×** in its header: at the right end of the panel's and the
right dock's tab row and of the popup lane's header, at the start of each left-dock section's title (a long title
cannot push it out of the dock); `x` where the terminal is not UTF-8,
and the panel, the right dock and the popup lane close with `Esc` or `q` (**Close Pane**, bound in all three key
profiles): the panel and the right dock hide (size and tabs kept), a popup ends, and focus goes to the editor you
used last. The keys only act where you read, not where you type: in a buffer you can edit `q` types a `q`, `Esc` is the Meta
prefix (`Esc x` is `M-x`) and, in the Vim profile, still leaves insert state, and a terminal tab (`comint`,
`eshell`, `term`, `vterm`, `eat`; `drgnx-close-input-modes`), a live page you are driving and the minibuffer keep
both keys. A mode that takes the keyboard for itself joins by adding a predicate to `drgnx-close-input-functions`. In a terminal frame `Esc` stays the Meta prefix, so use
`q` or the × there. The left dock's sections keep `Esc` as Back to the Editor (the sidebar stays); its ×, or Close
Pane in the palette, hides the sidebar. In the Vim profile the two keys close a read-only pane in normal and motion
state too (Close Pane's keys come before evil's, `drgnx-modal-front-alists`); in visual state `Esc` stays evil's and
leaves the selection.

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

Not yet: file nesting, icons (an icon theme is a module, M4), problems decorations (with diagnostics, M5).

## How it works

- **The change bus** (`wb/drgnx-signal.el`) is where followers subscribe. Window answers come from the workbench
  state store (`wb/drgnx-state.el`), which watches the window hooks; the bus listens to the buffer hooks. A hook
  only arms one idle flush (and notes which part changed: the buffer set, or the modified flags); the flush brings
  the store up to date, rebuilds only the part that changed, compares the state with the previous one and emits
  **edges**: `editor-changed` (the file in the editor you used last), `editor-point-changed` (its cursor moved),
  `frame-changed` (another frame became the selected one), `buffer-set-changed`, `modified-changed`. Followers
  subscribe to these, never to hooks — so a focus change, a background buffer or a burst of events cannot make
  them fire. Internal buffers (names starting with a space) never count. A follower (or a window-setup function)
  that fails is recorded in `drgnx-signal-errors`; the others still run and the next flush stays armed.
- **The editor you used last** is kept per frame, and is right at once: the moment a command ends (or a timer's
  change is drawn), not after the next pause. Each frame — a second window of the workbench, a terminal client —
  has its own, so a file chosen in one frame's dock opens in that frame's editor. Moving between two windows on one
  file changes the editor but not the file, so the Explorer and the Outline stay as they are.
- **Roles** (`wb/drgnx-wb.el`): each window is an `editor` or a `dock` window (window parameter `drgnx-role`). The
  dock is side windows with a pixel width kept across hide/show, no scroll bars, and titles in the
  `header-line-format` *window parameter*, where no mode can erase them. Showing the dock never takes focus; files
  chosen in it go to the most recently used editor window, never splitting it. Sections are registered with
  `drgnx-wb-define-section` (slot, title, height, buffer, `:on-show`); a title may be a function, asked each time
  the dock shows, so a panel's Find or filter stays in its title across hide/show. The dock's buffers are internal
  (` *drgnx explorer*`, ` *drgnx buffers*`, ` *drgnx outline*` — a leading space), so `C-x b` and ibuffer never
  list them. While `drgnx-rules-mode` is on, `drgnx-role` and `drgnx-section` are in
  `window-persistent-parameters`: a saved window state (`window-toggle-side-windows`, `window-state-put`) brings
  windows back with their roles.
- **Owned windows.** Code running from a timer or a follower may move only windows that show its own buffer, and
  says so with `drgnx-wb-with-owned-windows`; the harness's jank guard records any other window move made from a
  timer or a window change hook (invariant I9). Two lints (`test/unit/lint-buffers-timers-test.el`) keep the habits behind it: the
  workbench follows on the bus's edges, never from `run-with-timer`/`run-at-time` or a wall-clock
  `drgnx-timer-*` (an allow-list names the exceptions and why), and an internal ` *…*` buffer is made with `inhibit-buffer-hooks`, so no follower hears of it.
- **Explorer** (`wb/drgnx-explorer.el`) and **Buffers** (`wb/drgnx-buffers.el`) are **virtual lists**: the buffer
  holds plain text, inserted in one go; a vector holds what each line is (path, depth, folder or file — or the
  buffer); faces are painted by jit-lock for the rows on screen only. Expanding a folder inserts its rows after the
  folder's row; collapsing deletes them; nothing else is redrawn. Folder listings are cached while the folder is
  unchanged (one `directory-files-and-attributes` call per folder), for at most 64 folders (the least recently shown goes first). The Buffers panel re-renders only when its rows
  changed and puts every window's view and selection back on the same buffers.

## Performance

`bin/drgnx test --bench` builds drgnx, makes a 25,000-file project (200 folders × 100 files, one 5,000-file
folder, a depth-8 file), and times the same operations with drgnx, treemacs and ibuffer in a GUI session — each
including a full redisplay; one-off operations are the median of 3, key presses the median of five rounds of the 95th percentile of 300 presses (the point goes back to the start between rounds).
The bench also counts the garbage collections that ran inside each of drgnx's measurements (and the time they took)
and prints them as `gc:` lines under the table, so a GC that lands in a measured window explains a jump.
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
| I9 | No window moved from a timer or a window change hook except the caller's own | every report's `guard_violations` = 0 |
| I10 | Each step settles within 250 ms, without oscillation | `drgnx-inv/i1-i9-i10-explorer-and-buffers-flows` |
| I11 | Under a tiling window manager, a resize the WM makes goes to the editors: docks and panel keep their pixel size | `drgnx-wm/i11-docks-keep-their-size-when-the-wm-resizes`, `drgnx-wm/popups-under-tiling-leave-no-trace` (`test/live/drgnx-tiling-test.el`, sway tier: `bin/drgnx test --container --ui --compositor sway`) |
| I12 | Across monitors, drgnx moves a window only when asked (Move to Monitor, Next, Previous) and in the restore of auxiliary windows; a restore moves no other window and no other app | `drgnx-wm/move-to-monitor-2-and-back`, `drgnx-wm/a-fullscreen-window-stays-fullscreen-on-its-new-monitor`, `drgnx-wm/restore-puts-the-aux-window-back-on-its-monitor`, `drgnx-wm/a-missing-monitor-on-restore-is-skipped`, `drgnx-wm/a-restore-under-sway-moves-nothing-else`, `drgnx-wm/mutter-explains-and-moves-nothing` (`test/live/drgnx-wm-test.el`; see Tests) |

Two Emacs behaviours the workbench corrects so that these hold: `balance-windows` on a whole frame (finder calls
it) balances only the editors, and a package calling `display-buffer-in-side-window` directly still gets the place
its buffer's rule names.

I11 holds while the docks fit: if the window manager makes the frame narrower than the docks' widths plus the
smallest editor, Emacs shrinks everything in proportion (by default the left dock is 32 columns, the right dock 50
and an editor at least 10 — with both docks shown, a frame needs about 92 columns). One limit remains: after you drag
a dock's or the panel's edge, the next resize by the window manager scales that dock again.

## Tests

Batch: `test/unit/wb-*-test.el` (bus, dock, Explorer, Buffers). GUI: `test/live/drgnx-workbench-test.el` (the dock
by real key presses: no focus taken, width identical over 10 hide/show cycles, titles, no scroll bars). Behaviour:
the ten Explorer and Buffers scenarios of [scenarios.md](../develop/scenarios.md), plus two for live updates (a folder
appearing during a held click; a folder appearing while browsing), are green on drgnx (`bin/drgnx test
--scenario --config drgnx`; driver `test/scenario/drivers/drgnx.el`).

### Moving windows between monitors, live

`test/live/drgnx-wm-test.el` runs the move and restore commands against a real window manager, two monitors of
1280x800 each, config `drgnx`, a temporary state root, in the harness's own compositor only (never yours). Each test
runs in the tier that names its compositor and is skipped in the others:

| Tier | Run | Tests |
|---|---|---|
| sway | `bin/drgnx test --container --ui --compositor sway` | all but the mutter one: move to monitor 2 and back, fullscreen kept, restore, a missing monitor, a restore moves nothing else |
| x11 (Xvfb, no window manager) | `... --compositor x11` | move and back, fullscreen kept, restore |
| i3 | `... --compositor i3` | move and back |
| kwin (`test/live/drgnx-wm-other-test.el`, the window managers' image) | `... --compositor kwin` | move to monitor 2 and back with Next, restore onto monitor 2 |
| niri (one output only) | `... --compositor niri` | detection, the output list, a restore's placement, a move, and an output niri does not have refused; no move between two outputs |
| mutter (the default) | `bin/drgnx test --container --ui` | the other-Wayland path (the session sets no `XDG_CURRENT_DESKTOP`, so not GNOME's own message): the command explains it cannot drive the compositor, names its own key, and moves nothing |

Narrow a run with `DRGNX_TEST_SELECTOR='"^drgnx-wm/"'`. Under sway the session's seat has no keyboard, so Emacs never
hears the focus-in event a focused window gets; the move tests deliver it themselves (sway's own focus, in its
tree, is the real one).

## Remote folders in the Explorer

A remote folder (a TRAMP name) is listed only by a command of yours: opening it (Open Remote…), Refresh, expanding or
opening a folder row, New File, Rename, Delete and Paste, and leaving Find. A redraw that nothing of yours started, such as the one after a git status or a window change,
shows the listing it already has and asks the host nothing; a remote folder that was never listed shows one row,
`(not listed — Refresh)`, and Enter or a click on that row refreshes. A checkout in a local folder forgets only the
local listings. Git decorations, inline blame, the Outline and the change gutter skip remote files, and sticky scroll
works from the buffer's text alone; see [remote.md](remote.md).

## Known limits of the restore

A client's window is restored from `server-after-make-frame-hook`. Two rare paths do not reach it, so that first
window opens without the saved layout (Restore Workbench Layout in the palette brings it back):

- a graphical frame made by `make-frame-on-display` from a terminal client (the hook runs for frames the server
  makes for a client, not for this one);
- a client whose window opens while isearch or a minibuffer is active, or whose `server-execute` signals an error
  (the server skips the hook then).

Both were left as they are on purpose: moving the restore off the hook risks the restore of the ordinary client
window, which works. They will get another restore entry point if one is seen in use.

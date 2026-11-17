# Layouts

A layout arranges the tiles of the window you work in (module `tools/layouts`): which docks show (the side bar,
the bottom panel, the right side), with what, and how the editor area is shaped ([tiling](workbench.md)). drgnx has
eight, and you can save your own.

| Layout | Side bar | Editor area | Right side | Bottom panel |
|---|---|---|---|---|
| **Agent** | Explorer | the editor and the current agent's chat tile, side by side | Agents | hidden (open it when you want it) |
| **Editor** | Explorer | your editors | hidden | as it was |
| **Zen** | hidden | the editor you used last, its text centred at 100 columns | hidden | hidden |
| **Browser** | hidden | the editor and a web page tile beside it | hidden | hidden |
| **Work** | Explorer | your editors, the one you used last on the Work map | the Work Detail | hidden |
| **Code** | Explorer | your editors | the Agents side | hidden |
| **Work + Code** | two windows: this one as Work, a second one as Code | | | |
| **Review** | hidden | the editor, the review screen and the changes by task | hidden | hidden |

**Agent** is the main workday, as in Zed: the file tree on the left, one file and one agent chat in the middle, and
the list of agents narrow on the right, with each agent's state and how long ago it last acted (the **Last**
column: `30s`, `5m`, `2h`, `3d`). The chat is a tile of its own showing the running agent that acted last; with no
agent running, it says how to start one (Agents: New Agent Session…).

**Zen** keeps the text at a readable width when the window is resized. Its command run again (View: Layout Zen)
goes back to where you came from: the layout you were in, or, if you had not picked a layout yet, the exact
arrangement you had. Zen Mode (module `ui/look`) still works on its own.

**Browser:** the editor with a web page beside it ([browser.md](browser.md)). In an Emacs without WebKit the tile
says so and pages open in your system browser.

**Work** keeps the Explorer and your editors: the Work space ([work-space.md](work-space.md)) is a view in the
editor, never a full-window layout. The editor you used last shows the newest Work map, and its Detail is docked on
the right. **Work + Code** is two windows: this one as Work, and a second one as Code, on your second monitor when
you have one (with one monitor, the window manager places it). Run it again and the same second window is used.

A tile whose content comes from a module that is off (or not written yet: the Agents side, the review screen, the
changes by task) shows a one-line placeholder; it fills in place when the module is turned on.

## Switching

| Command | VS Code | Emacs | Vim |
|---|---|---|---|
| View: Next Layout — Agent, Editor, Zen, Browser, Work, Code, Work + Code, Review, then yours, and around | `C-k l` | the palette | `SPC l n` |
| View: Layout… — pick one by name | the palette | the palette | `SPC l l` |
| View: Layout Agent / Editor / Zen / Browser / Work / Code / Work + Code / Review | the palette | the palette | the palette |
| View: Save Layout As… | the palette | the palette | the palette |
| View: Reset Tiles to the Layout | the palette | the palette | the palette |
| Restore Previous Layout | `C-k C-z` | `C-x w u` | `SPC l u` |

Switching back to a layout brings back the arrangement you left it in, not a fresh one: its tiles and their sizes,
the docks, your editors with their tabs, and the place in each file. Each window remembers this for itself.
Every switch is one step of **Restore Previous Layout**, which takes you back to the arrangement before it.
**Reset Tiles to the Layout** builds the current layout again from its definition, every docked tile back in its
dock (a tile you moved out of a dock is no dock's any more until then).

A layout only moves, shows and hides tiles. It never closes a file, stops an agent or ends a process, and never asks
anything: a file with unsaved changes, a terminal and an agent chat stay open. Going to Zen moves your other editors'
tabs to the one it shows, and going back brings the editors back. That includes leaving Zen for a layout you have not
used yet: it is built from the arrangement you had before Zen.

## Your own layouts

**View: Save Layout As…** asks for a name and saves the current arrangement of tiles as a layout of your own. You
are then in it, and Next Layout and Layout… offer it after the built-in ones. The built-in names are taken.

Your layouts are kept in `~/.config/drgnx/layouts.eld` (in your config folder: [where drgnx keeps its files](files.md#where-drgnx-keeps-its-files)),
each as its grid (`:tree`). A layout saved before the grid (its `:windows` and `:px`) is still read: its docks and
editors come back as a grid at their saved sizes.

Save Layout As… changes only the entry it saves: your other layouts, your comments and anything you added to the file
stay as they are, and an entry named like a built-in layout is kept. `nil`, `t` and names starting with a colon are
not layout names.

**A `layouts.eld` with a mistake:** your last good layouts are used, and drgnx says once where the mistake is
(`Open Config File…` takes you there). Save Layout As… waits until it is fixed: it never overwrites a file it cannot
read, and says so. A `layouts.eld` written by a newer drgnx is used when it fits, but is not changed.

## Per project, and after a restart

Each project keeps its own layouts: the current one, the arrangement of each layout you used, the layout before it
and the way back from Zen, in `~/.local/state/drgnx/layouts/PROJECT.eld` (`$XDG_STATE_HOME`). The project is the
Work space's workspace when `tools/work-space` is on, else one `global` file. The file is written two seconds after
an arrangement changes, and when Emacs exits; it is read when a window first works in the project, or when it
switches to another project (the window stays as it is: the next switch uses that project's arrangements).

The layout you were in is saved with the workbench ([workbench.md](workbench.md#the-layout-survives-a-restart))
and is your current layout again at the next start, so Next Layout carries on from it and Zen centres the text
again. The windows themselves come back as the workbench was; nothing is rearranged. Going back to another layout
after a restart brings it back as you left it; its files are opened again by name (nothing is asked, local files
only, at most 50 tabs per editor). An arrangement that is not valid (a crafted file) is left out, and that layout is
built fresh. A layout that no longer exists (a deleted one of yours) is ignored.

## For module authors

Layouts are data: `drgnx-layouts` holds the built-in ones as `(NAME :left VIEW :right KIND :panel KIND :editor
SHAPE)`, or `(NAME :frames (LAYOUT LAYOUT))` for two windows. For a dock, `nil` hides it and `keep` leaves it as it
was; a KIND is an area tab or a pane kind. Each is built as a grid TREE (`drgnx-layouts--build-tree`). Editor shapes
are registered in `drgnx-layouts-shapes` (SHAPE → a function of the editor area's node, its width and height in
frame pixels and the frame's scale, returning the editor area's node); add one with
`(drgnx-layouts-define-shape SHAPE FN)` (returns SHAPE), never by writing the variable. drgnx ships `one`,
`editor+agent`, `zen`, `work` and `review`, and the browser module adds `editor+browser`. A shape that is not
registered arranges as `one`.

A shape that adds a tile of its own content registers its kind with `(drgnx-layouts-define-pane KIND FILLER
&optional TITLE)`: a pane kind homed right whose FILLER (a function of the tile's window) fills it
(`drgnx-pane-define-kind` with `:fill`). A tile of that kind shown before its module set up (after a restart) shows
its placeholder and fills in place when the module defines it.

Both calls are undone when the module is turned off: called from a module's setup they push their own undo.
`drgnx-layouts-undefine-shape SHAPE` and `drgnx-layouts-undefine-pane KIND` do the same by hand. Your layouts keep
naming the shape (they arrange as `one` while it is gone), and a tile of a kind that is gone shows its placeholder.
`drgnx-layouts-apply` switches the selected window's layout. To keep your own data in the saved workbench, add a
function to `drgnx-persist-state-functions` (no argument, returns a plist for the selected frame) and read it back in
a `drgnx-persist-after-restore-functions` function from the frame parameter `drgnx-persist-extra`.

## Tests

`test/unit/layouts-grid-test.el` (prefix `drgnx-layouts-grid/`), `test/unit/mod-layouts-test.el` (the shape and pane
registration tests have the prefix `drgnx-layouts-shape/`), `test/unit/mod-layouts-persist-test.el` and
`test/unit/layouts-eld-test.el` (the file, prefix `drgnx-layouts-eld/`); `test/ui/layouts-presets-gui-test.el`
(`:compositor`, two monitors) puts Work + Code on two monitors and on one; `test/ui/editor-m11c1-test.el`
(`drgnx test --ui`) walks the Agent, Zen and Browser layouts with a screenshot of each.

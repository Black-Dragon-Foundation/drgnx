# Layouts

A layout arranges the window you work in: which areas show (the sidebar, the bottom panel, the right dock) and how
the editor area is shaped (module `tools/layouts`). drgnx has four, and you can save your own.

| Layout | Sidebar | Editor area | Right dock | Bottom panel |
|---|---|---|---|---|
| **Agent** | Explorer | the editor and the current agent's chat, side by side | Agents | hidden (open it when you want it) |
| **Editor** | Explorer | your editor groups | hidden | as it was |
| **Zen** | hidden | one window, its text centred at 100 columns | hidden | hidden |
| **Browser** | hidden | the editor and a web page beside it | hidden | hidden |

**Agent** is the main workday, as in Zed: the file tree on the left, one file and one agent chat in the middle, and
the list of agents narrow on the right, with each agent's state and how long ago it last acted (the **Last**
column: `30s`, `5m`, `2h`, `3d`). The chat is the transcript of the running agent that acted last; with no agent
running, the right half says how to start one (Agents: New Agent Session…). The work tracker has a tab in the
bottom panel too: open the panel (Toggle Panel) and pick **Work**. The layout does not move tabs between areas.

**Zen** keeps the text at a readable width when the window is resized. Its command run again (View: Layout Zen)
goes back to where you came from: the layout you were in, or, if you had not picked a layout yet, the exact
arrangement you had. Zen Mode (module `ui/look`) still works on its own.

**Browser:** the editor with a web page beside it ([browser.md](browser.md)), every other area hidden. In an Emacs
without WebKit the right half says so and pages open in your system browser.

## Switching

| Command | VS Code | Emacs | Vim |
|---|---|---|---|
| View: Next Layout — Agent, Editor, Zen, Browser, then yours, and around | `C-k C-l` | the palette | `SPC l n` |
| View: Layout… — pick one by name | the palette | the palette | `SPC l l` |
| View: Layout Agent / Editor / Zen / Browser | the palette | the palette | the palette |
| View: Save Layout As… | the palette | the palette | the palette |

Switching back to a layout brings back the arrangement you left it in, not a fresh one: the sizes of the sidebar
and docks, the tabs they showed, your editor groups with their tabs, and the place in each file. Each window
remembers this for itself, for as long as Emacs runs.

A layout only moves, shows and hides things. It never closes a file, stops an agent or ends a process. Going to
Zen hides your other editor groups, and going back brings them back. That includes leaving Zen for a layout you have
not used yet: it is built from the arrangement you had before Zen, not from Zen's single window.

The first time you use a layout, it is built from its definition. Editor keeps the editor groups you have and
takes away the agent chat that Agent added.

## Your own layouts

**View: Save Layout As…** asks for a name and saves the current arrangement as a layout of your own: which areas
show, their tabs and sizes, and how the editor area is split. You are then in it, and Next Layout and Layout… offer
it after the built-in ones. The built-in names (agent, editor, zen, browser) are taken.

Your layouts are kept in `~/.config/drgnx/layouts.eld` (`$DRGNX_CONFIG_DIR` when set), so they are there in the
next Emacs too. The first time you use one in a new Emacs, its windows show the buffers of the same names if they
are open.

## After a restart

The layout you were in is saved with the workbench ([workbench.md](workbench.md#the-layout-survives-a-restart))
and is your current layout again at the next start, so Next Layout carries on from it and Zen centres the text
again. The windows themselves come back as the workbench was; nothing is rearranged. A layout that no longer
exists (a deleted one of yours) is ignored. Only the main window's layout is kept.

## For module authors

Layouts are data: `drgnx-layouts` holds the built-in ones as `(NAME :left VIEW :right TAB :panel TAB :editor
SHAPE)`. For an area, `nil` hides it and `keep` leaves it as it was. Editor shapes are registered in
`drgnx-layouts-shapes` (SHAPE → a function of the editor window). drgnx ships `one`, `editor+agent` and `zen`, and
the browser pane (module `tools/browser`) adds `editor+browser`. A shape that is not registered arranges as `one`. `drgnx-layouts-apply`
switches the selected window's layout. To keep your own data in the saved workbench, add a function to
`drgnx-persist-state-functions` (no argument, returns a plist for the selected frame) and read it back in a
`drgnx-persist-after-restore-functions` function from the frame parameter `drgnx-persist-extra`.

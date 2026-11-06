# Agents in the editor

The module `tools/agents-in-editor` shows where agents are working in the files you have open. This page covers the
part that exists so far: which buffers are watched.

- A file buffer is watched while a window shows it, and not watched when no window does. A hidden buffer receives
  nothing from the agent hub and has nothing drawn in it. Remote files are never watched.
- Switching the buffer in a window, resizing windows and a restart of the hub all update the watches by themselves; you
  do not have to do anything, and nothing here asks you a question.
- Turn the module off (`tools/agents-in-editor`) and every watch ends at once and nothing is left behind.

## Cursors, rings and tags

- An agent that is editing a file you have open shows as a thin bar in its colour where it is typing. The bar moves as
  the agent moves; it is one bar per agent per buffer.
- An agent that is reading a range of lines shows a soft tint over those lines; one that is about to edit a range shows
  a dashed underline under them. Only the lines you can see are drawn, so a long range costs no more than a screenful.
- An agent that is working on the same file in another worktree has no bar and no tint in your buffer: a small tag at
  the line it maps to says what it is doing and where ("Opus · editing in rp-df-hub").
- A tag is the agent's mark, its name and what it is doing ("◆ Opus 2 · editing"). Without the Glitnir tags the name
  is in the bar's hover text. The setting `drgnx-agents-tags` chooses when tags show: `activity` (the default, two
  seconds after the agent moves), `always` or `never`. Two agents of one colour, and the agent you follow, keep their
  tags on.
- In a terminal the bar is the character under it in the agent's colour, inverted; the tint becomes a background
  colour; tags appear only in the agent line.

How the gutter and the agent line draw follows in later pages of this guide.

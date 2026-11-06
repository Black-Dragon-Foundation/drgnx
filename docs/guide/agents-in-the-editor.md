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

## The gutter

- On the lines an agent changed, the gutter shows the agent's colour in place of git's mark. A range the agent is about
  to change shows a hollow mark, a range that is in conflict with your own changes a hatched one; the first line of a
  changed range carries the agent's own shape (circle, square, triangle or diamond).
- Hover a mark for what it is ("Opus · changed in step 14 · 2 min ago"). The marks never rely on colour alone.
- Your own changed lines keep the git mark; where an agent and git mark the same line, the agent's wins. The strip
  works with git marks off.
- A terminal has no fringe, so the buffer gets a one-column left margin while an agent's lines are showing.

## The agent line

- The header, after the file's name, shows one line for the agent nearest your cursor: its mark, its name, what it is
  doing, the symbol it is in, and the step or plan entry it is on in quotes ("◆ Opus 2 · editing · parse_frame \"Wire
  the retry\""). With more agents in the file, "+N" says how many; clicking it opens who is in this file.
- "F follow" (or the command **Follow Agent**) keeps that agent's name tag on in your buffer; again, or with no agent
  near, stops.
- While the line shows, the breadcrumb shortens to the file name so both fit. A large file's header and sticky
  scroll's scopes come first and are never replaced.

How the Explorer, the status bar and the who-is-here list show agents follows in a later page of this guide.

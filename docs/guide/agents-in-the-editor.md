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
- "F follow" (or the command **Follow Agent**) follows that agent in a window of its own (see below) and keeps its
  name tag on in your buffer; again, or with no agent near, stops.
- While the line shows, the breadcrumb shortens to the file name so both fit. A large file's header and sticky
  scroll's scopes come first and are never replaced.

## The Explorer, the status bar and who is here

- **Explorer badges.** A file an agent is editing, is about to change or has changed shows the agent's mark and initial
  at the end of its row: up to three, then "+N". A folder shows one mark per agent with files under it. An agent
  working in its own worktree of your project lands on your tree's row for the same file.
- **Status bar.** The segment `agents-here` (after `jobs`) shows one mark for each agent working in this project,
  eight at most, then "+N". An agent that waits on you has its mark in the attention colour. Click it for who is here.
- **Who is here.** The command **Who Is Here** opens a small list window with one row per agent in the project (mark,
  name, what it does, file and line). On a row, RET opens the agent's file at its line and follows it, `o` opens the
  agent's panel, and `q` closes the list. (The keys are the profiles' rows for **Follow the Agent on the Row**, **Open
  the Agent's Panel from the Row** and **Close Who Is Here**.) **Who Is in This File** (`C-k h` in VS Code, `C-c w h`
  in Emacs, `SPC a h` in Vim) lists the agents in the current file the same way.

## Following an agent

**Follow Agent** (`agents-follow`: `C-c w f` in the Emacs profile, `C-k f` in VS Code, `SPC a f` in Vim) follows the
agent nearest your cursor in a window on the right. The window shows the agent's file in its worktree, read-only, with
point on the agent's cursor; the window scrolls only when that leaves its middle third. Its header line says "Following NAME · reading parse_frame — 'the agent's own step or plan entry'"
with "Esc stop · W take the wheel · o panel". A file the agent changes is read again in place, so the text you are
looking at stays put. The file is opened with only safe local variables (a `.dir-locals.el` an agent wrote asks
nothing and runs nothing), no large-file question and no language server.

- Moving about in the window (scrolling, a motion, a click, a search) pauses following: the header says "Paused
  following · F resumes", and `F` jumps back to the agent.
- Typing in the window does nothing but say "W takes the wheel from NAME".
- `Esc` or `q` ends following and closes the window; `o` opens the agent's panel. When the agent finishes, the header
  says so and the window stays until you close it.
- **Follow in This Window** (`agents-follow-here`, in the palette) follows in the window you are working in instead;
  any command there stops it at once.

## Take the wheel

**Take the Wheel from the Agent** (`agents-take-wheel`: `C-k W` in VS Code, `C-c w W` in Emacs, `SPC a W` in Vim; `W`
in a followed file or a file an agent is editing) stops the agent after its current step. The file stays read-only
and the echo area says "Stopping after Edit jobs.rs…" until the hub has stopped it; then it is yours: "You hold
NAME's wheel · W gives it back". Pressing **W** again (or **Give the Wheel Back**, `agents-give-wheel`) gives it back:
for an agent in a worktree of its own your modified buffers there are saved first, without a question, and if one
cannot be saved the wheel stays yours and the message lists it. A chat works in your own checkout, so nothing is saved
for it. The agent is then sent what you changed. The panel header says "held by you" meanwhile.

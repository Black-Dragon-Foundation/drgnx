# Agents in the editor

The module `tools/agents-in-editor` shows where agents are working in the files you have open. This page covers the
part that exists so far: which buffers are watched.

- A file buffer is watched while a window shows it, and not watched when no window does. A hidden buffer receives
  nothing from the agent hub and has nothing drawn in it. Remote files are never watched.
- Switching the buffer in a window, resizing windows and a restart of the hub all update the watches by themselves; you
  do not have to do anything, and nothing here asks you a question.
- Turn the module off (`tools/agents-in-editor`) and every watch ends at once and nothing is left behind.

How the agents are drawn (cursors, rings, the gutter, the agent line) follows in later pages of this guide.

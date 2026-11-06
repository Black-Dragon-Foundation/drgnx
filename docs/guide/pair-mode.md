# Pair mode

Pair mode lets a chat edit your own checkout, live, in the files you have open, while you keep typing. It is off
unless the matrix's `chat.project-edit` row allows it: Cautious never, Balanced lets you turn Pair on for a chat,
Autonomous starts chats paired ([security.md](security.md), the matrix).

## What a paired chat can and cannot do

- **Its own tools stay read-only.** The sandbox still shows the checkout read-only to the chat: its shell, its own edit
  tools and anything it runs get "Read-only file system". A Claude chat in a project starts with Claude Code's
  `Edit`, `Write`, `MultiEdit` and `NotebookEdit` turned off; its `Read` stays.
- **It edits through drgnx.** A chat in a project has three drgnx tools: `read_file` (the file as your editor has it,
  unsaved edits included), `edit_file` (replace one exact piece of text) and `write_file` (the whole new text). Gemini's
  own file tools already ask drgnx to read and write, so they take the same way. With Pair off, the edit tools answer
  "pair mode is off; ask the user to turn it on".
- **Every write goes through your editor.** The hub sends it to the Emacs that has the file open, which applies it
  whole at a safe moment, or refuses it whole: nothing of a refused write is applied, and it is never applied later.
  The hub reports only what your editor answered, so a write it applied is never reported as refused.
- **A whole-file write needs a fresh read.** `write_file` of an existing file is refused unless drgnx served the read
  it is based on (the chat is told to read it with `read_file` and try again), so an old copy can never undo what you
  saved since.
- **Never these files:** `.git/`, the agents' own configuration (`.claude`, `.codex`, `.gemini`, `.envrc`,
  `mise.toml`), CI and build files (`.github/`, `Makefile*`, `build.rs`, `*.sh`), credential files, or anything outside
  the checkout, links included. `read_file` never hands over a credential file either.

## Turning Pair off

Turning Pair off for a chat closes its door at once: writes not yet in your editor are refused ("pair mode was turned
off by the user"), the ones waiting in your editor are dropped unapplied, and the chat is told in a note. Nothing it is
doing is cancelled. Pair mode cannot be turned on where the matrix says never. While you hold a chat's wheel its
writes are refused the same way.

## When a write is refused

The chat is told why, in words it can act on: the lines you are editing, "read it with read_file", "the editor is
away". After two refusals of one file within a minute it is told to wait for you or ask you, and its card shows which
file it waits on. A chat writes only files open in your editor: a file you have not opened is refused "not open in the
editor; ask the user to open it", and a file open as a large or remote file is refused too.

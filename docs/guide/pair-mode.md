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

## In your editor

The module `tools/agent-pair` is pair mode's side in Emacs:

- **A write waits for a safe moment.** It is applied between your commands: never while a command runs, while the
  minibuffer is open (a `completing-read`, a question), inside a keyboard macro or an isearch. Nothing asks you
  anything, and what you are typing in the minibuffer is never touched.
- **A write that waited too long is dropped.** Each write may wait 2 s, counted from when your Emacs received it; past
  that it is dropped unapplied and the chat is told the editor did not get to it. A write whose apply has started
  always finishes.
- **Your Emacs tells drgnx which files are open**, when you open, close or rename one (`write-file` too) and again
  after every reconnection, so a chat writes only the files you have open, and `read_file` gives the chat your
  buffer's text, unsaved edits included.
- **A write moves past what you typed since the chat read the file.** Lines you added or removed above the chat's
  change shift it to where its lines are now; if you changed the very lines it changes, the whole write is refused
  and the chat is told which lines you are editing. It is refused too when it would touch the line you are on (±1,
  in every window showing the buffer) or your active region, and when the chat's read is too old to shift from ("read
  it with read_file"). Shifting needs the edit history (Nidhogg .6 with Glitnir); without it a whole-file write is
  refused, and nothing is ever applied unshifted.
- **A chat's write is one undo step of its own.** `C-/` right after it takes the whole write away (every hunk) and
  nothing of yours; typing after it is a separate step, so undoing your typing never takes the chat's change with
  it. Point and your marks stay on their text. The edit history records the write as the chat's, not yours.
- **A read-only buffer, or a file another Emacs has locked, refuses the write.** If the file changed on disk and the
  buffer has none of your edits, it is quietly read again first; with your unsaved edits the write is refused.
- **Saving never asks.** A write to a buffer with no unsaved edits is saved right after it is applied, so the chat's
  builds and tests see it; a buffer with your unsaved edits stays unsaved, and the chat is told the file on disk has
  neither yet. Your `before-save-hook` (a formatter) runs as usual; one that would ask a question stops the save.
  Anything the save would have asked (a coding
  system, a formatter's question, deleting old backups, a final newline set to ask) never shows: old backups are
  kept, the final newline is added, and otherwise the buffer stays unsaved and the chat is told "not saved: WHY".

## Turning Pair on and off

**Agents: Pair: Turn On or Off** (`agents-pair`, in the palette; the agent panel's Pair chip does the same) turns
pair mode on or off for a chat in your project, the one there is or the one you choose. Turning it off always works.
When it cannot be turned on it says why:

- "Pair is off: the matrix's chat.project-edit is never for this chat" — change the preset or the cell first;
- "Pair needs Nidhogg .6 with Glitnir" — the edit history pair mode needs is not in this Emacs (`drgnx doctor` says so in its `pair-mode` row);
- "Pair is not available for this agent yet: REASON" — Claude and Gemini have pair mode now; Codex, Kimi and DeepSeek
  get it once their own edit tools are proven off.

A chat whose writes of one file were refused twice says so: "Claude is waiting for lines 120–124 of main.rs".
Turning the module `tools/agent-pair` off turns pair off for the paired chats, drops what waits in the queue and
cancels nothing; what was applied stays.

## Turning Pair off

Turning Pair off for a chat closes its door at once: writes not yet in your editor are refused ("pair mode was turned
off by the user"), the ones waiting in your editor are dropped unapplied, and the chat is told in a note. Nothing it is
doing is cancelled. Pair mode cannot be turned on where the matrix says never. While you hold a chat's wheel its
writes are refused the same way, and so they are at once when you change the preset or a cell so that the matrix's
`chat.project-edit` becomes never for the chat.

## When a write is refused

The chat is told why, in words it can act on: the lines you are editing, "read it with read_file", "the editor is
away". After two refusals of one file within a minute it is told to wait for you or ask you, and its card shows which
file it waits on. A file open in your editor is written only through it; a file open as a large or remote file is
refused. A file you have not opened is written on disk by the hub, only if it is still exactly what the chat last read
("changed since you read it; read it with read_file" otherwise): atomically, keeping its permissions, owner, extended
attributes and SELinux context, its line ends and byte-order mark, and recorded in the edit history as the chat's
edit.

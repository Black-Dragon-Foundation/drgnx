# Large files

Opening a big file never freezes drgnx. A file larger than **50 MiB** (`:ask-above`) opens in one of three ways:

| Mode | What you get |
|---|---|
| **Chunks** | One part of the file at a time, 1 MiB by default (`:chunk-size`). Moving to the next part reads only that part, so even a file of many gigabytes opens at once. Undo works in a chunk. Needs the package vlf (the module `editor/large-files-chunks`). |
| **Lean** (Open Whole) | The whole file, without the expensive extras: no syntax colours, line numbers, current-line highlight, tree-sitter parser, language server, indent guides, inline blame, sticky scroll or gutter changes, and no undo or auto-save. |
| **Raw** | The whole file, literally: the bytes as they are on disk, without decoding, and lean as above. |

A buffer that holds a large file says so in its header line, with a button for each other mode:

```
412 MB, in chunks: [Open Whole] [Open Raw]
```

The status bar shows the same, on the right: `412 MB · chunk 3/412`, `412 MB · lean` or `412 MB · raw`.

## What asks, and what never does

**A file you open yourself asks once:** a click or RET in the Explorer, Open File, quick open, a link in the Work
cockpit or the AI pane. The question appears at the bottom of the window:

```
big.log is 412 MB: [c]hunks [n]ormal (lean) [r]aw [q]uit
```

The answer listed first is the default: lean below 500 MiB (`:chunks-above`), chunks above it. `q` cancels the open.
drgnx remembers your answer for that file until you quit (for up to 256 files), so opening it again does not ask.

**Everything else never asks.** It takes the answer you gave for that file, or else **chunks**:

- `drgnx open BIG` and `drgnx -t BIG` from a terminal ([opening.md](opening.md)).
- The windows drgnx brings back at start, and layouts.
- Timers, agents and anything else drgnx does by itself.

Some callers need the whole text and open it **lean**, without asking: `drgnx open --wait BIG` (drgnx as your
`$EDITOR`), Replace, the AI's Apply Hunk and the agent edit review. Agents never read a large file from its buffer:
they read the disk, and a file over their size limit is refused as before.

A file that is already open is reused as it is, in the mode it has.

## Switching

Each header button is also a command, in the palette (File):

- **Large File: Open in Chunks**
- **Large File: Open Whole (lean)**
- **Large File: Open Raw**

Switching closes the buffer and opens the file again in the new mode, in the same window, and remembers the new mode
for the file. It is refused while the buffer has unsaved changes ("Save or revert big.log first: switching reopens
the file").

In chunks, **Large File: Next Chunk**, **Previous Chunk**, **Go to Line** (a line of the whole file) and **Search**
(the whole file, chunk by chunk) move through the file. In the VS Code profile they are `Alt+PageDown`,
`Alt+PageUp` and `M-g g`; everywhere, vlf's own `C-c C-v n`, `p`, `l` and `s` work.

## When the file changes

A revert (by hand, or by auto-revert when an agent or a program writes the file) follows the size without asking. A
lean file that shrinks to 50 MiB or less becomes a normal buffer again, with its colours, line numbers and language
server. A normal file that grows past 50 MiB turns lean. A raw file stays raw, and a file in chunks stays in chunks.

## Long lines

A file with very long lines (minified JavaScript, a one-line JSON) slows Emacs down at any size. drgnx turns on
Emacs's `so-long` everywhere: such a buffer opens in `so-long-mode`, with the same expensive extras off.

## The settings

`~/.config/drgnx/large-files.eld` ([reference](../reference/config.md#large-filesel)), sizes in MiB, fractions
allowed:

```elisp
(:version 1 :ask-above 50 :chunks-above 500 :chunk-size 1)
```

- `:ask-above`: above this size a file opens in chunks, lean or raw. `nil` turns the feature off: files open as
  Emacs opens them.
- `:chunks-above`: above this size the question's default is chunks; below it, lean.
- `:chunk-size`: how much of the file one chunk holds.

A project can carry `.drgnx/large-files.eld` with `:ask-above` and `:chunks-above`. It can **only lower** your sizes:
a higher value, `nil` or a `:chunk-size` there is ignored, so a repository cannot make drgnx load a huge file whole.
With your `:ask-above` nil, the project file is not read.

## GUI and terminal

Both behave the same: the same sizes, the same question in the minibuffer, the same modes. In a terminal the header
buttons can be clicked only when the mouse is on ([terminal.md](terminal.md)); the commands work everywhere.

## Without vlf

The chunks need the package vlf, which drgnx installs with the module `editor/large-files-chunks` (pinned in the
shipped lock). Without it, every "chunks" becomes **raw**: the question has no `[c]`, and an automatic open gives a
raw buffer. Turning the module `editor/large-files` off brings back Emacs's own behaviour: its own question above
`large-file-warning-threshold` (10 MB unless you set it), and no lean, raw or chunks. Buffers that were lean keep their major mode until you
revert them; buffers in chunks stay as they are.

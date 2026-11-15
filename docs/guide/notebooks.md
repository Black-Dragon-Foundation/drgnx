# Notebooks

A Jupyter notebook (`.ipynb`) opens as one buffer of **cells**, each a card of its own: a header strip, the source you
type, and its output underneath. The module is `lang/notebook` (Preferences: Modules). Notebooks run on any kernel
installed on your machine (the kernelspecs Jupyter would list); the kernel runs as you, unsandboxed, like a terminal.

## What you see

- **A header strip** on each cell: a run button (a stop button while the cell runs), then the count (`[3]` after a run, `[*]` while it runs, `[ ]` before) and the language, each in a chip; a markdown or raw cell shows its type. On the selected cell a toolbar at the right edge has icons to move the cell up or down, delete it, and a **more** icon that offers copy, cut, paste, split, merge, change type, clear outputs and the run commands; each is also a command (Cell Menu… for the last).
- **The source** is ordinary text. Undo, search and replace, multiple cursors, completion and every other Emacs command
  work across cells.
- **The output** sits under the cell: text, streams, errors and static images. Output from the file, not from a run in
  this session, is shown quieter. Inline output is capped at 20 rows (and 8 KiB); the last row says how many more lines
  there are. **Copy Output** copies the whole text of the cell's output.
- The cell you are in is tinted; the others are a step quieter. On a graphical Nidhogg each cell is a **card**: a rounded
  ring around its rows (the focus colour on the selected cell of the focused window only). Without Glitnir's blocks, and in
  a terminal, it is the band look: each cell's rows tinted, a hairline over the header.

## The status bar

In a notebook the bar shows the selected cell's place (`cell 3 of 4 · python`) and the kernel with its state (`● python3 · busy`; `no kernel` before the first run), as the hub reports them.

## Running

| Command | VS Code | Emacs | Vim |
|---|---|---|---|
| Run Cell | `C-RET` | `C-c C-c` | `SPC n n` |
| Run Cell and Advance | `S-RET` | `C-c C-n` | `SPC n N` |
| Run All Cells | `C-k n r` | `C-c C-r` | `SPC n r` |
| Run Cells Above / Run Cell and Below | `C-k n u` / `C-k n d` | `C-c C-u` / `C-c C-d` | `SPC n u` / `SPC n d` |
| Interrupt Kernel | `C-k n i` | `C-c C-i` | `SPC n i` |
| Restart Kernel / and Run All | `C-k n k` / `C-k n K` | `C-c C-k` / `C-c C-S-k` | `SPC n k` / `SPC n K` |
| Select Kernel… | `C-k n e` | `C-c C-e` | `SPC n e` |

The first run starts the kernel the notebook names (`kernelspec` in the file), else one for its language; when several
fit, you are asked. A kernel's `input()` asks you in the minibuffer.

## Editing cells

Every cell command is in the palette (category Notebook) and has a key in each profile (keys sheet). The boundary between
cells is two read-only characters; `kill-region` across one says "use Cut Cell" and does nothing, and a yank of copied
boundaries gives plain text.

- **Add Cell Below / Above**, **Delete Cell**, **Move Cell Up / Down**, **Split Cell** (at point; the first part keeps the
  id and the output), **Merge Cell With the Next**, **Change Cell Type…**.
- **Cut Cell, Copy Cell, Paste Cell**: a cell clipboard of its own (a pasted cell gets a new id).
- **Toggle Outputs** hides or shows all outputs; **Clear Outputs** clears them all in the hub (a prefix argument: only this cell's), leaving a queued or running cell alone.
- Under the selected cell, a row of **+ Code** and **+ Markdown** buttons adds a cell below.

## Saving

Saving writes the notebook through the hub, which changes only what you edited: untouched cells and outputs keep their
bytes. A notebook with no cell ids gets them on the first saving edit. The file is never edited as text while its buffer
is open; a file that is not a notebook opens as text.

If the hub restarts, every open notebook is opened again on the new hub by its file and given your cells, so unsaved edits stay
in the buffer and the next save writes them. The kernel is gone with the old hub: it starts again on the next run, and the
buffer shows no kernel until then. Outputs come back from the file. A notebook opened while no hub was there waits, read-only, and opens when the hub is up.

## Syntax colours and pictures

A cell's source is coloured by its language's tree-sitter mode when the language has a grammar installed ([language packs](editing.md#language-support-tree-sitter)): one parser per language for the whole notebook, whose ranges are the union of that language's cells (a markdown cell uses the markdown grammar). Without a grammar the cell is plain text.

PNG and JPEG outputs are drawn under the cell (at most 240 px tall, so a cell never scrolls past a window); the first draw fetches the image from the hub, and until it arrives a label (`[image/png 640×360]`) stands in. SVG is not drawn in this first version.

## The outline, a cell's whole output and the kernel's log

Three views the hub builds, shown in their own buffers (drgnx's own Emacs):

- **Show Cell Outline** (`C-k n j` in the VS Code keys, `C-c C-j` in Emacs, `SPC n l` in Vim): one row per cell with its number, type, prompt, first line and state (queued, running, error, aborted, cancelled). `RET` goes to the cell (Go to Cell).
- **Open Output** (`C-k n O`): the whole output of the cell at point, a window of 1000 lines at a time; `M-n` and `M-p` (Output: Later and Earlier Lines) move the window. Images are a row you can save as a file, never drawn here; a kernel's SVG is not rendered.
- **Show Kernel Log** (`C-k n L`): what the kernel says that answers no cell, such as its own logging.

Each follows the notebook while it is open, ends with it, and is asked for again when the hub restarts. In a terminal Emacs without these views, Open Output shows the output as text in a buffer of its own, and the other two say they need drgnx's own Emacs.

## Not yet

The card look has a ring but not yet the mockup's shadow, the gaps between cards, and the output inside the ring (Glitnir's blocks do not draw them yet); without blocks each cell is a tinted band with a hairline over its header. There are no toolbar or hover icons yet; every command is in the palette. Rich HTML and widget outputs show as their plain text.

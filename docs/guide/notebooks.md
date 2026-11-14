# Notebooks

A Jupyter notebook (`.ipynb`) opens as one buffer of **cells**, each a card of its own: a header strip, the source you
type, and its output underneath. The module is `lang/notebook` (Preferences: Modules). Notebooks run on any kernel
installed on your machine (the kernelspecs Jupyter would list); the kernel runs as you, unsandboxed, like a terminal.

## What you see

- **A header strip** on each cell: a run button, then what the hub says of the cell (`[3]  python` after a run, `[*]  python` while it runs, `[ ]  python` before; the cell's type for a markdown or new cell).
- **The source** is ordinary text. Undo, search and replace, multiple cursors, completion and every other Emacs command
  work across cells.
- **The output** sits under the cell: text, streams, errors and static images. Output from the file, not from a run in
  this session, is shown quieter. Inline output is capped at 20 rows (and 8 KiB); the last row says how many more lines
  there are. **Copy Output** copies the whole text of the cell's output.
- The cell you are in is tinted; the others are a step quieter. This is the band look (each cell's rows tinted, a chip
  for the run button and the type); it is also what a terminal shows.

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

## Syntax colours and pictures

A cell's source is coloured by its language's tree-sitter mode when the language has a grammar installed ([language packs](editing.md#language-support-tree-sitter)): one parser per language for the whole notebook, whose ranges are the union of that language's cells (a markdown cell uses the markdown grammar). Without a grammar the cell is plain text.

PNG and JPEG outputs are drawn under the cell (at most 240 px tall, so a cell never scrolls past a window); the first draw fetches the image from the hub, and until it arrives a label (`[image/png 640×360]`) stands in. SVG is not drawn in this first version.

## Not yet

The cell outline and the kernel's log wait for the hub's views (an Sjá view each); until then **Open Output** shows the cell's whole output as text in a buffer of its own. The card look (each cell a rounded card with a shadow, as in the mockup) waits for the compositor's block primitive: until then each cell is a tinted band with a hairline over its header. There are no toolbar or hover icons yet; every command is in the palette. Rich HTML and widget outputs show as their plain text.

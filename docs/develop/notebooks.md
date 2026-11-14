# Jupyter notebooks

`hrafn::notebook` reads and writes `.ipynb` files (nbformat 4.x) **without changing a byte nobody edited**, gives the editor
the one text a notebook buffer holds, and chunks each cell by its language's pack. The kernel and the view come later (the
design is in the org folder: `docs/specs/drgnx/2026-11-14-jupyter-tier1-design.md`).

## The model: byte spans, not a parsed value

Re-serialising a parsed `serde_json::Value` changes bytes (`1e-05` becomes `1e-5`, an integer above 2^53 becomes a float,
escapes are normalised, key order is lost). So `Notebook::parse` keeps the file's text and each cell's byte span in it (the
`cells` array is read as `&RawValue` elements):

- Untouched: `render()` returns the original bytes.
- Edited: the `cells` array is spliced. An untouched cell is its span, copied. An edited cell is re-emitted in nbformat's layout
  (`indent=1`, sorted keys, `(",", ": ")`, no ASCII escaping, a multiline string as a list of lines by Python's
  `splitlines(True)`; the file's own indent unit when it has another) with its unedited fields' values copied from their raw
  text. An added cell is a new element; a removed one leaves with its separator.
- Ids (a 4.5 cell needs one) are minted in memory on load. The first saving edit writes an id for every cell that lacks one and
  moves `nbformat_minor` to 5. A repeated id is not the file's: the later cell gets a fresh one.
- A file that is not a notebook (not JSON, not an object, no `cells`, `nbformat` below 4, a cell that is not a cell) is a
  `NotANotebook`: the caller opens it as text and never rewrites it.
- New outputs are written by `serde_json` with their keys sorted (what `sort_keys` does); a float a kernel sent is printed as
  Rust prints it.

`minimal.edited.ipynb` in the tests' fixtures is nbformat's own writer's output for an edit (`test/notebooks/make-goldens.py`,
run with nbformat installed): the test compares bytes.

## The view

`Notebook::view()` is the text of the editor's buffer: for each cell a head boundary newline, the source, a tail boundary newline
(the editor puts the cell's header and output strings on the boundaries). Its lines are the buffer's lines.

## The chunker

`Lang::Notebook` (`.ipynb`): each non-empty cell is chunked by its language (a code cell by the notebook's
`kernelspec.language`, markdown by Markdown, raw as text), the chunks and symbols are put in the view's offsets and lines, and a
chunk's FTS path and header say `file.ipynb#CELL-ID`. Outputs are not indexed. A file that is not a notebook reads as text.

## Saving

The hub writes a notebook the way every hub write goes: to a temporary file in the same folder, then a rename over the notebook. A
notebook that is a symbolic link is therefore replaced by a regular file with the same name; the file the link pointed at is not
changed. (Keep a notebook that must stay a link in the folder the link points into, or save it from a tool that follows links.)

Outputs are written the way nbformat's writer writes them: multiline text as a list of lines, one output object per output, keys
sorted. A cell that was not run in this session keeps the outputs the file had, byte for byte. A notebook file is read up to 32 MiB;
the outputs read from it go through the same limits as a kernel's (64 outputs and 1 MiB of text per cell, 16 MiB of images, 200
traceback entries, an output larger than 8 MiB shown as a line saying so).

## The hub's notebooks and kernels

`notebook/*` (the table in `hub.md`) is the editor's door; every method is the user's (an agent cannot start a kernel), and a kernel is
refused in a sealed session (`kernel::refuse_when_sealed`). The editor owns what the user types: it calls `notebook/open` (the buffer's
text, else the file; the answer carries the tails of the first 200 cells with output, within 1 MiB, and `more_tails`, how many cells
with output have none yet: `notebook/tail` gives those; cell sources over 8 MiB in all are refused), `notebook/sync` with all its cells when it wants the hub to have them, then `notebook/execute` with the cells to
run (their text becomes the notebook's first) and `notebook/save` (which takes the cells again when given). `notebook/start` starts the
kernel (the notebook's `metadata.kernelspec.name`, else its language's, else the name given); `notebook/restart` ends it (asked, its
process group killed after the grace) and starts a new one with a new connection file and key; `notebook/shutdown`,
`notebook/interrupt`, `notebook/input`, `notebook/clear`, `notebook/tail`, `notebook/output` (the whole output as nbformat objects)
and `notebook/close` are what they say.

**How the hub reaches a kernel.** Over ipc by default: the connection file (0600, in the session's 0700 folder) names socket files
beside it, and they go with the kernel (the hub removes any a kernel leaves; ipykernel leaves them). A kernel that cannot use ipc is
started once more over loopback tcp, and the error, if that fails too, names both attempts; a kernelspec can say it only works over
tcp (`"metadata": {"drgnx_transport": "tcp"}` in its `kernel.json`; `"ipc"` is the default and any other value makes the kernelspec
unusable). Only a start whose process ended before it made any socket counts as a refusal: a kernel that started and was not ready is
not tried again. Over tcp the hub claims a block of ports (`debug::ports`, held for the kernel's life), writes `127.0.0.1` and those
ports into the connection file, and before it connects to a port it asks `debug::ports::owned` whether the kernel's own process (or
its children) listens there: a listener that is someone else's is an error naming the port, and nothing is sent to it. The HMAC key
signs every message either way. The heartbeat channel is not used; the process's end is the death signal.

The hub sends the editor that opened a notebook three events, only for what changed:

- `notebook-tail`: a cell's tail, built whole (text, style runs as terminal face roles, images, `more_lines`, `version`, `stale`,
  `execution_count`) with the cell's head (`[n]`/`[ ]`/`[*]` and the kind, `state` `idle`, `queued` or `running`); at most 20 a
  second per cell. The editor only puts the strings.
- `notebook-status`: `state` (`starting`, `idle`, `busy`, `dead`), the running `cell` and the length of the `queue`.
- `notebook-input-request`: a kernel's question (`cell`, `request`, `prompt`, `password`); answer it with `notebook/input`.

A cell is done when its `execute_reply` and its `idle` status have both come (they travel on different sockets). An error aborts the
cells queued behind it (shown "aborted"), an interrupt or a restart cancels them ("cancelled"). Everything a kernel sends is held under
the limits in the output model: 64 outputs and 1 MiB of text per cell, 16 MiB of images, a message of more than 16 MiB is a note, a flood
(64 MiB unread, or 1000 messages that do not verify in 10 s) kills the kernel.

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

## The buffer (Lisp)

`modules/lang/drgnx-notebook.el` (module `lang/notebook`) is the editor's side. A cell in the buffer is a head, the source and a
tail; the head and the tail are each one read-only newline carrying the text property `drgnx-cell` `(ID . head|tail)` and
`drgnx-cell-type`, so undo, kill and yank move cells as text, and the cell ranges are read back from the property (a binary
search over the cached ranges; a rescan walks the property's changes, never the text, after a quiet moment, never on a
keystroke). The chrome is overlays on the boundary characters: the head's `before-string` (the header strip) and the tail's
`after-string` (the output the hub built: `notebook-tail`, put as it came, its runs' roles as the faces
`drgnx-notebook-fg-ROLE`/`-bg-ROLE`, with `overlay-put`, which writes no undo entry, sets no modified flag and runs no change
function). A boundary that comes back by undo or yank has no overlay, and the rescan asks the hub for that cell's tail by id.

The hub calls it makes (`drgnx-notebook--call`): `notebook/open {path, text}`, `/sync {id, cells}` then `/execute {id, cells}`
(the cells to run), `/save {id, cells}`, `/kernels`, `/start {id, kernel}`, `/shutdown`, `/interrupt`, `/input`, `/tail {id,
cell}`, `/output {id, cell}`, `/close`; it listens to `notebook-tail`, `notebook-status` and `notebook-input-request`.

The header strip is a `before-string` on the head boundary (an `after-string` of a one-character head would land on the source's
first row, so the strip would have no row of its own); the output is an `after-string` on the tail boundary, ending in the newline
Lisp adds. The Lisp header is a stopgap: the hub is to build the head as it builds the tail, and the Lisp builder goes when it does.

**Tree-sitter** (`drgnx-notebook--sync-parsers`): one parser per language for the buffer, its included ranges the union of the
cells of that language (the notebook's language for code cells, `markdown` for markdown cells); the same rescan that finds the
boundaries moves the ranges. Font-lock comes from the languages' `LANG-ts-mode` settings, read once from a scratch buffer and
joined (`drgnx-notebook--setup-treesit`). **Order matters:** `treesit-major-mode-setup` deletes the buffer's overlays, so it runs
on the inserted text before the first rescan makes the chrome.

**Images**: a tail marks each image with one character (U+FFFC) and carries its output index, MIME type and size; Lisp fetches
`notebook/output` once per cell (the cache is dropped when the cell runs again) and draws PNG and JPEG as an `image` display
spec, a label until then.

## A hub that came back

The hub keeps notebooks in memory, so a restarted hub holds none, and the ids of the old one mean nothing (the editor never builds or
parses an id; it keeps the one it was given). `drgnx-hub-connected-functions` runs `drgnx-notebook--reconnect-all`: each notebook
buffer that visits a file asks `notebook/open` by its path (no text: the file is the hub's), takes the new id (the buffer table, the
status, no kernel), forgets the tails' versions (the new hub counts from the start), then sends `notebook/sync` with its cells as they
are at the time the answer arrives and puts the tails the open returned. The buffer's text is never replaced, so unsaved edits stay and
are the hub's after the sync. An open the hub refuses leaves the buffer and its id as they are, with a message.

An open that got no answer because there was no hub, or it went away first (the error is this side's string; a refusal is the hub's
plist, asked for with `:full`), leaves the buffer a read-only notebook buffer holding the file's text, marked `drgnx-notebook--retry`;
the same hook asks that open again, with the text, at the next connect. Only a refusal turns the buffer into plain text.

## The hub's notebooks and kernels

`notebook/*` (the table in `hub.md`) is the editor's door; every method is the user's (an agent cannot start a kernel), and a kernel is
refused in a sealed session (`kernel::refuse_when_sealed`). The editor owns what the user types: it calls `notebook/open` (the buffer's
text, else the file), `notebook/sync` with all its cells when it wants the hub to have them, then `notebook/execute` with the cells to
run (their text becomes the notebook's first) and `notebook/save` (which takes the cells again when given). `notebook/start` starts the
kernel (the notebook's `metadata.kernelspec.name`, else its language's, else the name given); `notebook/restart` ends it (asked, its
process group killed after the grace) and starts a new one with a new connection file and key; `notebook/shutdown`,
`notebook/interrupt`, `notebook/input`, `notebook/clear`, `notebook/tail`, `notebook/output` (the whole output as nbformat objects)
and `notebook/close` are what they say.

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

**The real shapes (T11b routed).** The header is the hub's: each tail carries a `head` (`text`, `state`, `runs`); the editor draws the
run button (and the add-cell buttons under the selected cell) and puts the hub's text after it, a cell with no head yet (new,
markdown) showing its type. `notebook/restart` is the hub's. The picker for `notebook/kernels` lists the skipped kernelspecs with
their reasons and refuses one. The notebook ids are the hub's to make (never parsed or built here), every method is checked against the
buffer's connection, and a notebook ends with that connection.

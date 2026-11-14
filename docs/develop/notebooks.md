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

# The UI's reactive engine (`tafl`)

`crates/ui/tafl` computes every value the UI shows. It is the one reactive mechanism for UI state: the
[ui-reactivity](standards/ui-reactivity.md) standard forbids any other (observers, callbacks that hold state, dependency
lists, channels carrying state).

## Cells

- A **state** (`Engine::state`) holds a value written by a command, an input or a model patch.
- A **formula** (`Engine::formula`) is a closure over other cells: `move |r| a.get(r) + b.get(r)`. Handles are 8-byte
  `Copy` values, so a `move` closure captures them with no `clone()`.
- A formula runs only when something pulls it: a visible block, an a11y node, an agent's subscription
  (`Engine::frame`, `Engine::pull`). When its new value equals the old one (`PartialEq`), its readers stay clean: the
  **cutoff**.
- Reads take `&Rd`, which exists only while the engine runs a formula. Writes take `&mut Wr`, which exists only inside
  `Engine::write`. So a read outside a formula, and a write inside one, do not compile
  (`tests/compile/*.rs`).
- A formula that panics keeps its old value. Its error is readable in place (`Engine::error`, `Engine::try_pull`), and
  the frame commits.

## Propagation

The engine pushes dirty marks and pulls on demand (the Reactively colouring algorithm), with salsa's durability.

- A transaction compares each write with the old value. When it ends, one marking pass marks the changed cells' direct
  readers **dirty** and their transitive readers **check**. Marking runs no user code.
- Pulling a check cell first brings its formula sources up to date; when none changed, the cell is clean without
  running.
- Edges come from the reads of each run. They are reused when a re-run reads the same sources in the same order, so a
  steady re-run allocates nothing (`a_steady_rerun_allocates_nothing`).
- A **durable** state (theme, fonts, settings, scale; `Engine::durable`) makes every cell that reads only durable states
  durable too: other writes never revalidate it.

## Memory

- Cells live in **slabs**, one per document or presentation instance (`Engine::slab`). `Engine::drop_slab` frees the
  slab's cells and edges together.
- Cell data is stored in columns (structure of arrays). Each cell has two sources and three readers inline; more go to
  a dense side arena.
- The figure is about 90 bytes per formula cell, with its value, closure and edges (`benches/tafl_cells.rs`, gate G3).
- Named states (`Engine::named_state`) outlive their slab in the **state table**. An instance made again finds them
  by (document, key path, name). Only values that differ from the initial value are kept, and
  `snapshot_states`/`restore_states` carry them over a rebuild.

## Models and collections

- A model type is declared with `tafl::model!`. Each object is one cell with a 64-bit changed-field mask, so a patch
  (`Obj::update`) dirties only the readers of the fields it changed. Fields are read as `obj.name(r)`.
- A `List` is versioned, with an epoch and a splice log (1,024 splices and 8,192 items at most). A reader follows the
  list by splices. A reader behind the trimmed log starts over once. A reset of an older epoch is ignored.
- `len` is kept, not counted, and `window` reads only its rows' items.
- `filter`, `sort_by` and `filter_by` turn an upstream splice into a downstream one:
  - `filter` tests new and patched items only;
  - `sort_by` moves a changed item with two binary searches;
  - `filter_by` takes a plain predicate. Over 10,000 items it runs on the work pool, and the old result stays,
    `busy`, until the new one lands. With `Monotone::Yes`, a refined key filters only the previous result.
- `wire::apply` turns the hub's windowed list (`sja::model::List`) into splices.

## Time and frames

- `Engine::clock(grain)` is a cell holding the time aligned down to its grain; clocks of one grain are one cell.
- The engine arms one timer, for the nearest deadline, and only while some clock has a reader. With no reader there is
  no timer.
- `Engine::frame(roots, budget)` does the following, in order:
  1. lands finished pool jobs and applies a due clock tick;
  2. brings the roots up to date, whole blocks only, until the budget is spent;
  3. leaves the rest to go first in the next frame.
- Writes before a frame coalesce into one frame request.

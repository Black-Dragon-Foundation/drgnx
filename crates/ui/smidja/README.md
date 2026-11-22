# smidja

Smiðja ("the smithy") is the workbench model behind drgnx's native workbench: the state of every OS window's regions
(rail, left, center, right, bottom), the center's groups and tabs, the selection, focus, overlays and folding, and the
intents that change them. It knows nothing of drawing or of Emacs: the realiser asks it what to show
(`realisation`), tells it what was shown (`set_edges`), and sends it intents; everything else follows from the rules.

- **Declarations** (`decl.rs`): tab kinds, page kinds, places, selection kinds and bottom kinds, declared by drgnx at
  start and by the hub as it comes up; the defaults (sizes, limits, the TTY's cells).
- **Intents** (`intent.rs`, `focus.rs`, `layout.rs`, `preset.rs`, `temp.rs`, `multi.rs`): open, pin, close, select,
  navigate, focus, side and bottom, overlays, splits and the other layout intents, presets, temporary layouts, OS
  windows and monitors. Each takes an origin: a program's intent never changes what shows (it marks), a user's does.
  A refused intent returns its reason and changes nothing.
- **Folding** (`fold.rs`): the right folds to a strip when the center would drop under 900 px (80 columns), then the
  left under 800 px (60 columns); a folded side asked for opens as an overlay.
- **Layout undo**: every layout change pushes a snapshot of the window's center (50 kept); restoring one makes its
  tabs again from their refs and skips what is gone.
- **Queries** (`query.rs`, `realise.rs`): the realisation in device pixels, the roles tree for accessibility and
  tests, and `query(window, path)` as tokens.
- **Persistence** (`persist.rs`): `save` writes the layout as text ("smidja-layout 1"), `load` reads it, and the
  restore state machine resolves its refs as Emacs and the hub find them. Smidja does no I/O: drgnx writes the files.
- **The rules** (`rules.rs`): W1–W10 (the design's §4.5) as checks over a state and over one step; `sim.rs` steps
  random intents of both origins over 1–3 OS windows, pixel and cell sizes.

## Crate rules

- Standard library only; no I/O, no threads, no rendering knowledge.
- Every change bumps the version; the realiser's edges for an older version are ignored.
- Builds on Rust 1.93 (the glue's floor). A path dependency of the glue, so libnhglue.a holds it.

## Checks

`check.sh --container fedora-45`: fmt, clippy (`-D warnings`), the tests (`tests/rules.rs` runs W1–W10 after every
step of seeded random sequences), the licence policy. `../smidja-fuzz` (`cargo run --release -- --seconds N`) runs
the same rules over new seeds for a given time.

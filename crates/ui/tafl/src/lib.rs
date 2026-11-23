//! tafl (*tafl*, the board game's board): the UI's reactive engine (docs/develop/engine.md, the ui-reactivity standard).
//!
//! Every value the UI computes is a cell. A [`State`] is written by a command, an input or a model patch; a [`Formula`]
//! is a closure `move |r| …` over other cells, run only when something pulls it (a visible block, an a11y node, an
//! agent's subscription) and cut off when its new value equals the old. Reads take `&`[`Rd`], which exists only while
//! the engine runs a formula; writes take `&mut `[`Wr`], which exists only inside [`Engine::write`]. So a read outside a
//! formula, and a write inside one, do not compile.
//!
//! - Propagation: push dirty, pull on demand (the Reactively colouring algorithm) with salsa's durability; edges are
//!   reused when a re-run reads the same sources in the same order (Preact), so a steady re-run allocates nothing.
//! - Model objects ([`Model`], [`tafl::model!`](model!)) are one cell each with a 64-bit changed-field mask: a patch
//!   dirties only the readers of the fields it changed. Collections ([`List`]) are versioned with a splice log, and
//!   `filter`, `filter_by` and `sort_by` turn an upstream splice into a downstream one.
//! - Cells live in slabs, one per document or presentation instance, freed with it; state survives by name in the state
//!   table. Time is a clock cell that has a timer only while something reads it.
//!
//! This crate owns the ui-reactivity standard: no other reactive or observer mechanism for UI state.

mod cell;
mod clock;
mod durable;
mod edge;
mod engine;
mod frame;
mod list;
mod model;
mod ops;
mod propagate;
mod rd;
mod slab;
mod splice;
mod state_table;
mod stats;
pub mod wire;

pub use cell::{CellId, Durability, Formula, Origin, Stage, State, Value};
pub use engine::{Engine, FormulaError};
pub use frame::FrameOut;
pub use list::{List, Monotone, Version, Window};
pub use model::{FieldDef, FieldSet, Model, ModelRef, Obj, Schema};
pub use rd::{Rd, Wr};
pub use slab::{InstanceKey, SlabId};
pub use splice::{Key, Splice};
pub use state_table::{StateKey, StateSnapshot};
pub use stats::Stats;

//! The read context of a formula and the write transaction.

use crate::CellId;
use crate::cell::Value;
use crate::engine::Engine;
use crate::model::{Model, ModelRef, Obj};
use crate::propagate::{ALL, OBJECT};
use crate::slab::StateNode;

/// The read context: exists only while the engine runs a formula. Every read through it is recorded as an edge.
pub struct Rd<'e> {
    pub(crate) e: &'e Engine,
}

/// A write transaction: exists only inside [`Engine::write`]. Its writes are marked in one pass when it ends.
pub struct Wr<'e> {
    pub(crate) e: &'e Engine,
}

impl Rd<'_> {
    pub(crate) fn read<T: Value>(&self, c: CellId) -> T {
        self.e.core.read_with(self.e, c, ALL, |v: &T| v.clone())
    }

    /// A model field's value, recorded as (object, field bit). Called by the code `tafl::model!` generates.
    #[doc(hidden)]
    pub fn read_field<M: Model, F: Clone>(&self, o: ModelRef, bit: u32, get: fn(&M) -> &F) -> F {
        self.e
            .core
            .read_with(self.e, o.cell, 1u64 << bit, |v: &M| get(v).clone())
    }
}

impl Wr<'_> {
    pub(crate) fn set<T: Value>(&mut self, c: CellId, v: T) {
        self.e.core.set(c, v);
    }

    pub(crate) fn peek<T: Value>(&self, c: CellId) -> T {
        self.e
            .core
            .value_of::<T>(self.e, c)
            .unwrap_or_else(|err| panic!("tafl: {}", err.message))
    }

    pub(crate) fn patch<T: Model>(&mut self, c: CellId, f: impl FnOnce(&mut T)) {
        self.e.core.patch::<T>(c, f);
    }

    /// A new model object holding V.
    pub fn insert<T: Model>(&mut self, v: T) -> Obj<T> {
        let core = &self.e.core;
        let cell = core.alloc(core.model_slab.get(), Box::new(StateNode(v)), OBJECT, 0);
        Obj::from_ref(ModelRef { cell, aux: 0 })
    }
}

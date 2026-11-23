//! The cell handles: [`State`] and [`Formula`], their id, stage, durability and the origin of a write.

use std::marker::PhantomData;

use crate::rd::{Rd, Wr};

/// What a cell can hold: compared on every write and every re-run (`PartialEq` is the cutoff), cloned on every read.
/// Collections are compared by version, never deep: hold a [`crate::List`], not a `Vec`, for anything long.
pub trait Value: Clone + PartialEq + 'static {}
impl<T: Clone + PartialEq + 'static> Value for T {}

/// A cell's place in the engine: its slot and the slot's round (a handle to a dropped cell is caught, not reused).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub struct CellId {
    pub(crate) idx: u32,
    pub(crate) round: u32,
}

/// A state cell: a value written by a command, an input or a model patch. 8 bytes, `Copy`: a `move` closure captures it
/// with no `clone()`.
pub struct State<T>(pub(crate) CellId, PhantomData<fn() -> T>);

/// A formula cell: a closure over other cells, run on demand and cut off when its value comes out equal.
pub struct Formula<T>(pub(crate) CellId, PhantomData<fn() -> T>);

impl<T> Clone for State<T> {
    fn clone(&self) -> Self {
        *self
    }
}
impl<T> Copy for State<T> {}
impl<T> Clone for Formula<T> {
    fn clone(&self) -> Self {
        *self
    }
}
impl<T> Copy for Formula<T> {}

impl<T> State<T> {
    pub(crate) fn new(id: CellId) -> Self {
        State(id, PhantomData)
    }

    /// The cell's id (a demand root, an error's cell).
    pub fn id(self) -> CellId {
        self.0
    }
}

impl<T> Formula<T> {
    pub(crate) fn new(id: CellId) -> Self {
        Formula(id, PhantomData)
    }

    /// The cell's id (a demand root, an error's cell).
    pub fn id(self) -> CellId {
        self.0
    }
}

impl<T: Value> State<T> {
    /// The value, read inside a formula: the read is recorded as an edge.
    pub fn get(self, r: &Rd) -> T {
        r.read::<T>(self.0)
    }

    /// Write V. An equal value is a no-op; else the cell's dependents are marked when the transaction ends.
    pub fn set(self, w: &mut Wr, v: T) {
        w.set(self.0, v);
    }

    /// Write F of the current value (read-modify-write inside a transaction).
    pub fn update(self, w: &mut Wr, f: impl FnOnce(&T) -> T) {
        let v = w.peek::<T>(self.0);
        let n = f(&v);
        w.set(self.0, n);
    }
}

impl<T: Value> Formula<T> {
    /// The value, read inside a formula: brought up to date first, and the read recorded as an edge.
    pub fn get(self, r: &Rd) -> T {
        r.read::<T>(self.0)
    }
}

/// A cell's stage (ranked dirty kinds, after Unreal Slate): a frame processes them in order.
#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug, PartialOrd, Ord, Hash)]
pub enum Stage {
    State = 0,
    Formula = 1,
    Structure = 2,
    Measure = 3,
    Place = 4,
    Items = 5,
    Meaning = 6,
}

/// How often a cell's sources change (salsa's durability). `High`: theme, fonts, settings, scale; a keystroke never
/// revalidates a cell whose sources are all `High`.
#[derive(Clone, Copy, PartialEq, Eq, Debug, PartialOrd, Ord, Hash)]
pub enum Durability {
    Low,
    High,
}

/// Who wrote: the user's input, an agent, an extension, or a model patch (the hub, a clock tick, a landed job).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Origin {
    User,
    Agent(u64),
    Extension(u64),
    Model,
}

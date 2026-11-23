//! Slabs and the cells' nodes. A slab holds the cells of one document or presentation instance and is freed with it
//! (structural ownership: nested state cannot leak). A cell's node is its value and, for a formula, its closure, in one
//! allocation.

use std::any::Any;
use std::sync::Arc;

use crate::rd::Rd;

/// Which instance a slab belongs to: its document's name and its key path (the same path finds its state by name).
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct InstanceKey {
    pub doc: Arc<str>,
    pub path: Arc<[u32]>,
}

// written by hand: the name ends in `Key`, but it holds no secret (a document's name and a key path)
impl std::fmt::Debug for InstanceKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}{:?}", self.doc, self.path)
    }
}

/// A slab's handle.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct SlabId {
    pub(crate) idx: u32,
    pub(crate) round: u32,
}

/// A slab: the first of its cells (the rest are chained through the graph's `next` column), its round and owner.
pub(crate) struct SlabInfo {
    pub(crate) head: u32,
    pub(crate) round: u32,
    pub(crate) live: bool,
    #[allow(dead_code)] // the "why" audit (Task 16) names a cell's instance
    pub(crate) key: InstanceKey,
}

#[derive(Default)]
pub(crate) struct Slabs {
    pub(crate) v: Vec<SlabInfo>,
    pub(crate) free: Vec<u32>,
}

/// A cell's node: its value, and what computes it.
pub(crate) trait Node: 'static {
    /// Re-run: true when the value changed (false when it came out equal: the cutoff). A node with nothing to compute
    /// never runs.
    fn run(&mut self, _rd: &Rd) -> bool {
        false
    }
    fn value(&self) -> Option<&dyn Any>;
    fn value_mut(&mut self) -> Option<&mut dyn Any>;
    /// The value, moved out as the node is freed (the state table keeps it).
    fn into_value(self: Box<Self>) -> Option<Box<dyn Any>>;
    /// The node's own bytes (value and captures).
    fn bytes(&self) -> usize;
}

/// A state's (or a model object's, or a clock's) node: just its value.
pub(crate) struct StateNode<T>(pub(crate) T);

impl<T: 'static> Node for StateNode<T> {
    fn value(&self) -> Option<&dyn Any> {
        Some(&self.0)
    }
    fn value_mut(&mut self) -> Option<&mut dyn Any> {
        Some(&mut self.0)
    }
    fn into_value(self: Box<Self>) -> Option<Box<dyn Any>> {
        Some(Box::new(self.0))
    }
    fn bytes(&self) -> usize {
        std::mem::size_of::<Self>()
    }
}

/// A formula's node: its last value (none before the first good run) and its closure with the captures inline.
pub(crate) struct FormulaNode<T, F> {
    pub(crate) value: Option<T>,
    pub(crate) f: F,
}

impl<T: PartialEq + 'static, F: Fn(&Rd) -> T + 'static> Node for FormulaNode<T, F> {
    fn run(&mut self, rd: &Rd) -> bool {
        let new = (self.f)(rd);
        match &mut self.value {
            // the cutoff: an equal value leaves the cell's dependents clean
            Some(old) if *old == new => false,
            slot => {
                *slot = Some(new);
                true
            }
        }
    }
    fn value(&self) -> Option<&dyn Any> {
        self.value.as_ref().map(|v| v as &dyn Any)
    }
    fn value_mut(&mut self) -> Option<&mut dyn Any> {
        self.value.as_mut().map(|v| v as &mut dyn Any)
    }
    fn into_value(self: Box<Self>) -> Option<Box<dyn Any>> {
        self.value.map(|v| Box::new(v) as Box<dyn Any>)
    }
    fn bytes(&self) -> usize {
        std::mem::size_of::<Self>()
    }
}

/// A source collection's cell: its data is in the list table.
pub(crate) struct ListCellNode;

impl Node for ListCellNode {
    fn value(&self) -> Option<&dyn Any> {
        None
    }
    fn value_mut(&mut self) -> Option<&mut dyn Any> {
        None
    }
    fn into_value(self: Box<Self>) -> Option<Box<dyn Any>> {
        None
    }
    fn bytes(&self) -> usize {
        0
    }
}

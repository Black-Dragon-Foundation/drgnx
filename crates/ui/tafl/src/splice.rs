//! Splices: the changes of a versioned collection, and the stable keys they name items by.

use crate::cell::CellId;
use crate::model::ModelRef;

/// An item's stable key in a collection (its object's cell).
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Key(pub u64);

// written by hand: the name ends in `Key`, but it holds no secret (an item's cell)
impl std::fmt::Debug for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Key({:#x})", self.0)
    }
}

impl Key {
    pub(crate) fn of(c: CellId) -> Key {
        Key((u64::from(c.round) << 32) | u64::from(c.idx))
    }

    pub(crate) fn cell(self) -> CellId {
        CellId {
            idx: (self.0 & 0xffff_ffff) as u32,
            round: (self.0 >> 32) as u32,
        }
    }
}

/// One change to a collection: insert after an item (`None`: at the front), remove, move by stable key, or reset (a new
/// epoch: everything goes, `total` items are announced).
#[derive(Clone, Debug, PartialEq)]
pub enum Splice {
    Insert {
        after: Option<Key>,
        items: Vec<ModelRef>,
    },
    Remove {
        keys: Vec<Key>,
    },
    Move {
        key: Key,
        after: Option<Key>,
    },
    Reset {
        total: u64,
        epoch: u32,
    },
}

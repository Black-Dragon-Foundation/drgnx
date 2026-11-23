//! The incremental collection operators: `filter`, `sort_by` and `filter_by`. Each is a cell that keeps its edges
//! between runs (it links and unlinks item by item), follows its source collection by splices, and writes its result
//! as splices of its own collection.

pub(crate) mod filter;
pub(crate) mod pool;
pub(crate) mod sort;

use std::collections::HashSet;

use crate::cell::{CellId, Stage};
use crate::engine::Engine;
use crate::list::{Follow, List, ListData};
use crate::model::ModelRef;
use crate::propagate::{DIRTY, FORMULA, KEEP, add};
use crate::rd::Rd;
use crate::slab::Node;
use crate::splice::{Key, Splice};

/// A new operator: its collection in the list table and its cell, made by NODE (given the collection's row).
pub(crate) fn make<U>(e: &mut Engine, node: impl FnOnce(u32) -> Box<dyn Node>) -> List<U> {
    let core = &e.core;
    let aux =
        u32::try_from(core.lists.borrow().len()).unwrap_or_else(|_| panic!("tafl: too many lists"));
    let cell = core.alloc(
        core.model_slab.get(),
        node(aux),
        FORMULA | KEEP | DIRTY,
        Stage::Items as u8,
    );
    core.lists.borrow_mut().push(ListData::new());
    List::new(ModelRef { cell, aux })
}

/// What an operator learns of its source in one run.
pub(crate) struct Input {
    /// The source's items now.
    pub(crate) items: Vec<CellId>,
    pub(crate) version: u64,
    /// How to follow it from the version last seen.
    pub(crate) follow: Follow,
    /// The model objects the operator read that changed since its last run.
    pub(crate) changed: Vec<u32>,
}

/// Read the source SRC (recorded, brought up to date) and what changed since SEEN. With OUTSIDE_RESTARTS, a changed
/// outside source (a query the item closure read) is a restart.
pub(crate) fn input(
    r: &Rd,
    src: ModelRef,
    seen: u64,
    started: bool,
    outside_restarts: bool,
) -> Input {
    let core = &r.e.core;
    core.touch(r.e, src.cell);
    let my = core.current();
    let (outside, changed) = core.changed_sources(my, src.cell.idx);
    let lists = core.lists.borrow();
    let l = &lists[src.aux as usize];
    let follow = if !started || (outside && outside_restarts) {
        Follow::Restart
    } else {
        l.follow(seen)
    };
    if started && matches!(follow, Follow::Restart) {
        add(&core.n.resets, 1);
    }
    Input {
        items: l.items.clone(),
        version: l.version,
        follow,
        changed,
    }
}

/// The cells a splice list inserted, and the keys it removed.
pub(crate) fn delta(splices: &[Splice]) -> (Vec<CellId>, Vec<Key>) {
    let mut ins = Vec::new();
    let mut del = Vec::new();
    for s in splices {
        match s {
            Splice::Insert { items, .. } => ins.extend(items.iter().map(|r| r.cell)),
            Splice::Remove { keys } => del.extend_from_slice(keys),
            Splice::Move { .. } | Splice::Reset { .. } => {}
        }
    }
    (ins, del)
}

/// Make OUT hold NEW, logged as splices: the removed items in one splice, each run of new items in one insert. When
/// the items kept changed order, one reset (its readers start over). True when anything changed.
pub(crate) fn emit(out: &mut ListData, new: Vec<CellId>) -> bool {
    if out.items == new {
        return false;
    }
    let old_set: HashSet<CellId> = out.items.iter().copied().collect();
    let new_set: HashSet<CellId> = new.iter().copied().collect();
    let kept_old = out.items.iter().filter(|c| new_set.contains(c));
    let kept_new = new.iter().filter(|c| old_set.contains(c));
    let mut splices = Vec::new();
    if kept_old.ne(kept_new) {
        splices.push(Splice::Reset {
            total: 0,
            epoch: out.epoch,
        });
    } else {
        let gone: Vec<Key> = out
            .items
            .iter()
            .filter(|c| !new_set.contains(c))
            .map(|c| Key::of(*c))
            .collect();
        if !gone.is_empty() {
            splices.push(Splice::Remove { keys: gone });
        }
        let mut prev: Option<Key> = None;
        let mut run: Vec<ModelRef> = Vec::new();
        let mut run_after: Option<Key> = None;
        for c in &new {
            if old_set.contains(c) {
                if !run.is_empty() {
                    splices.push(Splice::Insert {
                        after: run_after,
                        items: std::mem::take(&mut run),
                    });
                }
            } else {
                if run.is_empty() {
                    run_after = prev;
                }
                run.push(ModelRef { cell: *c, aux: 0 });
            }
            prev = Some(Key::of(*c));
        }
        if !run.is_empty() {
            splices.push(Splice::Insert {
                after: run_after,
                items: run,
            });
        }
    }
    out.items = new;
    for s in splices {
        out.log_splice(s);
    }
    true
}

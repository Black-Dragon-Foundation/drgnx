//! `sort_by`: the items in key order (ties by item). A changed key moves its item alone: one key computed, one binary
//! search to take it out and one to put it back, one downstream move.

use std::any::Any;
use std::collections::HashMap;
use std::marker::PhantomData;

use super::{delta, emit, input};
use crate::cell::{CellId, Value};
use crate::engine::Engine;
use crate::list::{Follow, List};
use crate::model::{Model, ModelRef, Obj};
use crate::propagate::add;
use crate::rd::Rd;
use crate::slab::Node;
use crate::splice::{Key, Splice};

struct SortNode<T, K, F> {
    src: ModelRef,
    out: u32,
    seen: u64,
    started: bool,
    /// Every source item's key.
    keys: HashMap<u32, K>,
    /// (key, the item's stable key as the tie-break, the item), in order.
    sorted: Vec<(K, u64, CellId)>,
    f: F,
    _t: PhantomData<fn() -> T>,
}

pub(crate) fn make<T: Model, K: Ord + Value, F: Fn(Obj<T>, &Rd) -> K + 'static>(
    e: &mut Engine,
    src: List<T>,
    f: F,
) -> List<T> {
    super::make(e, |out| {
        Box::new(SortNode {
            src: src.model_ref(),
            out,
            seen: 0,
            started: false,
            keys: HashMap::new(),
            sorted: Vec::new(),
            f,
            _t: PhantomData::<fn() -> T>,
        })
    })
}

impl<T: Model, K: Ord + Value, F: Fn(Obj<T>, &Rd) -> K + 'static> SortNode<T, K, F> {
    fn key(&self, r: &Rd, c: CellId) -> K {
        (self.f)(Obj::from_ref(ModelRef { cell: c, aux: 0 }), r)
    }

    fn find(&self, k: &K, tie: u64) -> Result<usize, usize> {
        self.sorted
            .binary_search_by(|p| p.0.cmp(k).then(p.1.cmp(&tie)))
    }

    fn take_out(&mut self, k: &K, c: CellId) {
        if let Ok(i) = self.find(k, Key::of(c).0) {
            self.sorted.remove(i);
        }
    }

    fn put_in(&mut self, k: K, c: CellId) {
        let tie = Key::of(c).0;
        let i = self.find(&k, tie).unwrap_or_else(|i| i);
        self.sorted.insert(i, (k, tie, c));
    }
}

impl<T: Model, K: Ord + Value, F: Fn(Obj<T>, &Rd) -> K + 'static> Node for SortNode<T, K, F> {
    fn run(&mut self, r: &Rd) -> bool {
        let core = &r.e.core;
        let my = core.current();
        let inp = input(r, self.src, self.seen, self.started, true);
        let mut calls = 0u64;
        let mut touched = false;
        let mut structural = false;
        let mut moved: Vec<CellId> = Vec::new();
        match inp.follow {
            Follow::Same => {}
            Follow::Restart => {
                core.unlink_objects(my);
                self.keys.clear();
                self.sorted.clear();
                for c in &inp.items {
                    let k = self.key(r, *c);
                    calls += 1;
                    self.keys.insert(c.idx, k.clone());
                    self.sorted.push((k, Key::of(*c).0, *c));
                }
                self.sorted
                    .sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
                touched = true;
                structural = true;
            }
            Follow::Splices(s) => {
                let (ins, del) = delta(&s);
                for key in del {
                    let c = key.cell();
                    if let Some(k) = self.keys.remove(&c.idx) {
                        self.take_out(&k, c);
                        core.unlink(my, c.idx);
                    }
                }
                for c in ins {
                    let k = self.key(r, c);
                    calls += 1;
                    self.keys.insert(c.idx, k.clone());
                    self.put_in(k, c);
                }
                touched = true;
                structural = true;
            }
        }
        if self.started {
            for o in &inp.changed {
                let Some(old) = self.keys.get(o).cloned() else {
                    continue;
                };
                let c = core.id(*o);
                let new = self.key(r, c);
                calls += 1;
                if new != old {
                    self.take_out(&old, c);
                    self.keys.insert(*o, new.clone());
                    self.put_in(new, c);
                    moved.push(c);
                    touched = true;
                }
            }
        }
        self.seen = inp.version;
        self.started = true;
        add(&core.n.item_visits, calls);
        if !touched {
            return false;
        }
        let new: Vec<CellId> = self.sorted.iter().map(|p| p.2).collect();
        let mut lists = core.lists.borrow_mut();
        let out = &mut lists[self.out as usize];
        if !structural && moved.len() == 1 {
            // one item moved: one downstream move
            let c = moved[0];
            let at = new.iter().position(|x| *x == c).unwrap_or(0);
            if out.items == new {
                return false;
            }
            let after = at.checked_sub(1).map(|p| Key::of(new[p]));
            out.items = new;
            out.log_splice(Splice::Move {
                key: Key::of(c),
                after,
            });
            return true;
        }
        emit(out, new)
    }
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
        std::mem::size_of::<Self>()
            + self.keys.capacity() * (4 + std::mem::size_of::<K>())
            + self.sorted.capacity() * std::mem::size_of::<(K, u64, CellId)>()
    }
}

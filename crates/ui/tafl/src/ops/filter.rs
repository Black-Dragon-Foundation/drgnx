//! `filter`: the items for which a closure holds. An upstream insert tests the new items only, a removal tests
//! nothing, a patched item is tested again alone, and a changed outside source (a query) tests everything again.

use std::any::Any;
use std::collections::HashMap;
use std::marker::PhantomData;

use super::{delta, emit, input};
use crate::cell::CellId;
use crate::engine::Engine;
use crate::list::{Follow, List};
use crate::model::{Model, ModelRef, Obj};
use crate::propagate::add;
use crate::rd::Rd;
use crate::slab::Node;

struct FilterNode<T, F> {
    src: ModelRef,
    out: u32,
    seen: u64,
    started: bool,
    /// Every source item tested, and whether it passed.
    member: HashMap<u32, bool>,
    f: F,
    _t: PhantomData<fn() -> T>,
}

pub(crate) fn make<T: Model, F: Fn(Obj<T>, &Rd) -> bool + 'static>(
    e: &mut Engine,
    src: List<T>,
    f: F,
) -> List<T> {
    super::make(e, |out| {
        Box::new(FilterNode {
            src: src.model_ref(),
            out,
            seen: 0,
            started: false,
            member: HashMap::new(),
            f,
            _t: PhantomData::<fn() -> T>,
        })
    })
}

impl<T: Model, F: Fn(Obj<T>, &Rd) -> bool + 'static> FilterNode<T, F> {
    fn test(&mut self, r: &Rd, c: CellId) -> bool {
        let ok = (self.f)(Obj::from_ref(ModelRef { cell: c, aux: 0 }), r);
        self.member.insert(c.idx, ok);
        ok
    }
}

impl<T: Model, F: Fn(Obj<T>, &Rd) -> bool + 'static> Node for FilterNode<T, F> {
    fn run(&mut self, r: &Rd) -> bool {
        let core = &r.e.core;
        let my = core.current();
        let inp = input(r, self.src, self.seen, self.started, true);
        let mut calls = 0u64;
        let mut touched = false;
        match inp.follow {
            Follow::Same => {}
            Follow::Restart => {
                core.unlink_objects(my);
                self.member.clear();
                for c in &inp.items {
                    self.test(r, *c);
                    calls += 1;
                }
                touched = true;
            }
            Follow::Splices(s) => {
                let (ins, del) = delta(&s);
                for k in del {
                    let c = k.cell();
                    if self.member.remove(&c.idx).is_some() {
                        core.unlink(my, c.idx);
                    }
                }
                for c in ins {
                    self.test(r, c);
                    calls += 1;
                }
                touched = true;
            }
        }
        if self.started {
            for o in &inp.changed {
                if self.member.contains_key(o) {
                    self.test(r, core.id(*o));
                    calls += 1;
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
        let new: Vec<CellId> = inp
            .items
            .iter()
            .copied()
            .filter(|c| self.member.get(&c.idx).copied().unwrap_or(false))
            .collect();
        emit(&mut core.lists.borrow_mut()[self.out as usize], new)
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
        std::mem::size_of::<Self>() + self.member.capacity() * 8
    }
}

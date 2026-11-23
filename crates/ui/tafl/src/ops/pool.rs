//! `filter_by` and the operators' jobs on the work pool. The predicate is a plain function of an item and a key (no
//! cell reads), so over 10,000 items it runs on the pool on a snapshot; the old result stays, marked busy, until the
//! new one lands (in the next frame, or [`crate::Engine::settle_blocking`]).

use std::any::Any;
use std::collections::HashMap;
use std::pin::Pin;
use std::task::{Context, Poll, Waker};

use super::{delta, emit, input};
use crate::cell::{CellId, Value};
use crate::engine::Engine;
use crate::list::{Follow, List, Monotone};
use crate::model::{Model, ModelRef};
use crate::propagate::{ALL, add};
use crate::rd::Rd;
use crate::slab::Node;

/// Over this many items, `filter_by` runs on the pool.
pub(crate) const POOL_OVER: usize = 10_000;

/// A job on the pool: whose result it is (the operator's cell and collection) and its task.
pub(crate) struct Job {
    op: u32,
    out: u32,
    task: saman::Task<Vec<bool>>,
}

struct FilterByNode<T, K, KF> {
    src: ModelRef,
    out: u32,
    seen: u64,
    key: KF,
    pred: fn(&T, &K) -> bool,
    monotone: Monotone<K>,
    /// The key of the result shown (none before the first, and while a job computes a new one).
    last: Option<K>,
    member: HashMap<u32, bool>,
    /// What the job on the pool computes: its key, the source's version and the items, in order.
    pending: Option<(K, u64, Vec<CellId>)>,
}

pub(crate) fn make<T, K, KF>(
    e: &mut Engine,
    src: List<T>,
    key: KF,
    pred: fn(&T, &K) -> bool,
    monotone: Monotone<K>,
) -> List<T>
where
    T: Model + Send + Sync,
    K: Value + Send + Sync,
    KF: Fn(&Rd) -> K + 'static,
{
    super::make(e, |out| {
        Box::new(FilterByNode {
            src: src.model_ref(),
            out,
            seen: 0,
            key,
            pred,
            monotone,
            last: None,
            member: HashMap::new(),
            pending: None,
        })
    })
}

impl<T, K, KF> FilterByNode<T, K, KF>
where
    T: Model + Send + Sync,
    K: Value + Send + Sync,
    KF: Fn(&Rd) -> K + 'static,
{
    /// Test item C against K on this thread (and read it: a patch to it re-runs the operator).
    fn test(&mut self, r: &Rd, c: CellId, k: &K) -> bool {
        let core = &r.e.core;
        let v: T = core.object(c);
        core.record(c.idx, ALL);
        let ok = (self.pred)(&v, k);
        self.member.insert(c.idx, ok);
        ok
    }

    /// Send the whole test to the pool, on a snapshot of the items.
    fn spawn(&mut self, r: &Rd, k: K, version: u64, items: Vec<CellId>) {
        let core = &r.e.core;
        let my = core.current();
        let vals: Vec<T> = items
            .iter()
            .map(|c| {
                core.record(c.idx, ALL);
                core.object(*c)
            })
            .collect();
        let pred = self.pred;
        let key = k.clone();
        let task = core.pool.spawn("tafl-filter-by", async move {
            vals.iter().map(|v| pred(v, &key)).collect::<Vec<bool>>()
        });
        let mut jobs = core.jobs.borrow_mut();
        jobs.retain(|j| j.op != my);
        jobs.push(Job {
            op: my,
            out: self.out,
            task,
        });
        self.pending = Some((k, version, items));
        self.last = None;
    }
}

impl<T, K, KF> Node for FilterByNode<T, K, KF>
where
    T: Model + Send + Sync,
    K: Value + Send + Sync,
    KF: Fn(&Rd) -> K + 'static,
{
    fn run(&mut self, r: &Rd) -> bool {
        let core = &r.e.core;
        let my = core.current();
        let k = (self.key)(r);
        let inp = input(r, self.src, self.seen, self.last.is_some(), false);
        let landed = core.lists.borrow_mut()[self.out as usize].landed.take();
        let was_busy = core.lists.borrow()[self.out as usize].busy;
        match (landed, self.pending.take()) {
            (Some(bools), Some((pk, pv, items))) if pk == k && pv == inp.version => {
                self.member = items.iter().zip(bools).map(|(c, ok)| (c.idx, ok)).collect();
                self.last = Some(k);
                self.seen = pv;
                let new: Vec<CellId> = items
                    .iter()
                    .copied()
                    .filter(|c| self.member.get(&c.idx).copied().unwrap_or(false))
                    .collect();
                let mut lists = core.lists.borrow_mut();
                let out = &mut lists[self.out as usize];
                out.busy = false;
                return emit(out, new) || was_busy;
            }
            (None, Some(p)) if p.0 == k && p.1 == inp.version => {
                // the job computing this very result is still running
                self.pending = Some(p);
                return false;
            }
            _ => {}
        }
        core.jobs.borrow_mut().retain(|j| j.op != my);
        let refines = match (&self.monotone, &self.last) {
            (Monotone::Yes(f), Some(old)) => old == &k || f(old, &k),
            (Monotone::No, Some(old)) => old == &k,
            (_, None) => false,
        };
        let full = !refines || matches!(inp.follow, Follow::Restart);
        let mut calls = 0u64;
        if full {
            core.unlink_objects(my);
            self.member.clear();
            if inp.items.len() > POOL_OVER {
                self.spawn(r, k, inp.version, inp.items);
                let mut lists = core.lists.borrow_mut();
                let out = &mut lists[self.out as usize];
                out.busy = true;
                return !was_busy;
            }
            for c in &inp.items {
                self.test(r, *c, &k);
                calls += 1;
            }
        } else {
            if self.last.as_ref() != Some(&k) {
                // a refined key: only the previous result can still match
                let shown: Vec<u32> = self.member.iter().filter(|m| *m.1).map(|m| *m.0).collect();
                for o in shown {
                    self.test(r, core.id(o), &k);
                    calls += 1;
                }
            }
            if let Follow::Splices(s) = &inp.follow {
                let (ins, del) = delta(s);
                for key in del {
                    let c = key.cell();
                    if self.member.remove(&c.idx).is_some() {
                        core.unlink(my, c.idx);
                    }
                }
                for c in ins {
                    self.test(r, c, &k);
                    calls += 1;
                }
            }
            for o in &inp.changed {
                if self.member.contains_key(o) {
                    self.test(r, core.id(*o), &k);
                    calls += 1;
                }
            }
        }
        add(&core.n.item_visits, calls);
        self.last = Some(k);
        self.seen = inp.version;
        let new: Vec<CellId> = inp
            .items
            .iter()
            .copied()
            .filter(|c| self.member.get(&c.idx).copied().unwrap_or(false))
            .collect();
        let mut lists = core.lists.borrow_mut();
        let out = &mut lists[self.out as usize];
        out.busy = false;
        emit(out, new) || was_busy
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

/// A job's result: kept for its operator's next run, which is marked (and a frame requested).
fn deliver(e: &Engine, op: u32, out: u32, res: villa::Result<Vec<bool>>) {
    let core = &e.core;
    match res {
        Ok(bools) => core.lists.borrow_mut()[out as usize].landed = Some(bools),
        Err(err) => {
            tracing::warn!(%err, "a filter job failed; the operator computes again");
        }
    }
    if !core.is_live(core.id(op)) {
        return;
    }
    let mut stack = core.take_vec();
    let marks = core.g.borrow_mut().mark_dirty(op, &mut stack);
    core.give_vec(stack);
    add(&core.n.marks, marks);
    if marks > 0 {
        core.request_frame();
    }
}

/// Land the jobs that finished (a frame does this first).
pub(crate) fn land(e: &mut Engine) {
    let waker = Waker::from(e.core.shared.clone());
    let mut cx = Context::from_waker(&waker);
    let mut done = Vec::new();
    {
        let mut jobs = e.core.jobs.borrow_mut();
        let mut i = 0;
        while i < jobs.len() {
            if let Poll::Ready(res) = Pin::new(&mut jobs[i].task).poll(&mut cx) {
                let j = jobs.swap_remove(i);
                done.push((j.op, j.out, res));
            } else {
                i += 1;
            }
        }
    }
    for (op, out, res) in done {
        deliver(e, op, out, res);
    }
}

/// Wait for every job and land it.
pub(crate) fn settle(e: &mut Engine) {
    loop {
        let jobs = std::mem::take(&mut *e.core.jobs.borrow_mut());
        if jobs.is_empty() {
            return;
        }
        let pool = e.core.pool.clone();
        for j in jobs {
            let res = pool.block_on(j.task);
            deliver(e, j.op, j.out, res);
        }
    }
}

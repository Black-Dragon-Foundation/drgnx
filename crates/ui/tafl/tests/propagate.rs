//! Propagation: push dirty, pull on demand, dynamic dependencies, durability, steady re-runs, slabs.

mod common;

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::rc::Rc;

use proptest::prelude::*;
use tafl::{Formula, Origin, Stage, State};

/// Counts allocations made on a thread while its `COUNTING` is set.
struct Counting;

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
    static ALLOCS: Cell<u64> = const { Cell::new(0) };
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        if COUNTING.try_with(Cell::get).unwrap_or(false) {
            ALLOCS.with(|a| a.set(a.get() + 1));
        }
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        if COUNTING.try_with(Cell::get).unwrap_or(false) {
            ALLOCS.with(|a| a.set(a.get() + 1));
        }
        unsafe { System.realloc(p, l, n) }
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

fn counter() -> Rc<Cell<u32>> {
    Rc::new(Cell::new(0))
}

/// Writing the value a state already holds marks nothing and requests no frame.
#[test]
fn equal_write_marks_nothing() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let a = e.state(s, 3u32);
    let b = e.formula(s, Stage::Formula, move |r| a.get(r) + 1);
    assert_eq!(e.pull(b), 4);
    let before = e.stats();
    e.write(Origin::User, |w| a.set(w, 3));
    let after = e.stats();
    assert_eq!(after.marks, before.marks, "an equal write marked cells");
    assert_eq!(after.mark_passes, before.mark_passes);
    assert_eq!(after.frame_requests, before.frame_requests);
    e.write(Origin::User, |w| a.set(w, 5));
    assert!(
        e.stats().marks > after.marks,
        "an unequal write marked nothing"
    );
    assert_eq!(e.pull(b), 6);
}

/// a → b, a → c, (b, c) → d: one write runs each of b, c and d once.
#[test]
fn diamond_runs_each_cell_once() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let (nb, nc, nd) = (counter(), counter(), counter());
    let a = e.state(s, 1i64);
    let b = {
        let n = nb.clone();
        e.formula(s, Stage::Formula, move |r| {
            n.set(n.get() + 1);
            a.get(r) * 2
        })
    };
    let c = {
        let n = nc.clone();
        e.formula(s, Stage::Formula, move |r| {
            n.set(n.get() + 1);
            a.get(r) * 3
        })
    };
    let d = {
        let n = nd.clone();
        e.formula(s, Stage::Formula, move |r| {
            n.set(n.get() + 1);
            b.get(r) + c.get(r)
        })
    };
    assert_eq!(e.pull(d), 5);
    for i in 2..12i64 {
        e.write(Origin::User, |w| a.set(w, i));
        assert_eq!(e.pull(d), 5 * i);
    }
    assert_eq!((nb.get(), nc.get(), nd.get()), (11, 11, 11));
}

/// `if c { a } else { b }`: after c flips to false, a write to a re-runs nothing.
#[test]
fn dynamic_dependencies_follow_the_branch() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let runs = counter();
    let c = e.state(s, true);
    let a = e.state(s, 1u32);
    let b = e.state(s, 2u32);
    let f = {
        let n = runs.clone();
        e.formula(s, Stage::Formula, move |r| {
            n.set(n.get() + 1);
            if c.get(r) { a.get(r) } else { b.get(r) }
        })
    };
    assert_eq!(e.pull(f), 1);
    e.write(Origin::User, |w| c.set(w, false));
    assert_eq!(e.pull(f), 2);
    assert_eq!(runs.get(), 2);
    let marks = e.stats().marks;
    e.write(Origin::User, |w| a.set(w, 10));
    assert_eq!(
        e.stats().marks,
        marks,
        "a write to the branch not taken marked the formula"
    );
    assert_eq!(e.pull(f), 2);
    assert_eq!(
        runs.get(),
        2,
        "a write to the branch not taken re-ran the formula"
    );
    e.write(Origin::User, |w| b.set(w, 7));
    assert_eq!(e.pull(f), 7);
    assert_eq!(runs.get(), 3);
}

/// 1,000 re-runs that read the same sources in the same order allocate nothing (edges reused, values replaced in place).
#[test]
fn a_steady_rerun_allocates_nothing() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let a = e.state(s, 0u64);
    let b = e.state(s, 1u64);
    let f = e.formula(s, Stage::Formula, move |r| a.get(r) + b.get(r));
    let g = e.formula(s, Stage::Items, move |r| f.get(r) * 2);
    assert_eq!(e.pull(g), 2);
    // warm: the first re-runs size the engine's scratch
    for i in 1..10u64 {
        e.write(Origin::User, |w| a.set(w, i));
        e.pull(g);
    }
    COUNTING.with(|c| c.set(true));
    for i in 10..1010u64 {
        e.write(Origin::User, |w| a.set(w, i));
        e.pull(g);
    }
    COUNTING.with(|c| c.set(false));
    assert_eq!(ALLOCS.with(Cell::get), 0, "a steady re-run allocated");
    assert_eq!(e.pull(g), (1009 + 1) * 2);
}

/// A cell whose sources are all durable (the theme) is never revalidated by 1,000 low writes (keystrokes).
#[test]
fn a_keystroke_never_revalidates_durable_cells() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let theme_runs = counter();
    let theme = e.durable(s, 14u32);
    let text = e.state(s, String::new());
    let metric = {
        let n = theme_runs.clone();
        e.formula(s, Stage::Measure, move |r| {
            n.set(n.get() + 1);
            theme.get(r) * 2
        })
    };
    let line = e.formula(s, Stage::Items, move |r| (metric.get(r), text.get(r).len()));
    assert_eq!(e.pull(line), (28, 0));
    let verifies = e.stats().verifies;
    for i in 0..1000 {
        e.write(Origin::User, |w| {
            text.update(w, |t| format!("{t}{}", i % 10))
        });
        assert_eq!(e.pull(line).1, i + 1);
    }
    assert_eq!(theme_runs.get(), 1, "the durable cell re-ran");
    assert_eq!(
        e.stats().verifies,
        verifies,
        "a keystroke revalidated cells"
    );
    e.write(Origin::User, |w| theme.set(w, 16));
    assert_eq!(e.pull(line).0, 32);
    assert_eq!(theme_runs.get(), 2);
}

/// Dropping a slab frees its cells and edges: the counts go back to what they were before it.
#[test]
fn drop_slab_frees_every_cell_and_edge() {
    let (_sb, mut e) = common::engine();
    let base = e.slab(common::key("base", &[]));
    let shared = e.state(base, 1u32);
    let keep = e.formula(base, Stage::Formula, move |r| shared.get(r) + 1);
    assert_eq!(e.pull(keep), 2);
    let before = e.stats();
    let s = e.slab(common::key("doc", &[0]));
    let mut last: Option<Formula<u32>> = None;
    for i in 0..50u32 {
        let x = e.state(s, i);
        let prev = last;
        let f = e.formula(s, Stage::Formula, move |r| {
            x.get(r) + shared.get(r) + prev.map_or(0, |p| p.get(r))
        });
        last = Some(f);
    }
    let top = last.expect("a formula");
    assert!(e.pull(top) > 0);
    assert!(e.stats().cells > before.cells && e.stats().edges > before.edges);
    e.drop_slab(s);
    let after = e.stats();
    assert_eq!(after.cells, before.cells, "cells left after drop_slab");
    assert_eq!(after.edges, before.edges, "edges left after drop_slab");
    // the shared state's dependents are gone: a write marks nothing of the dropped slab
    e.write(Origin::User, |w| shared.set(w, 5));
    assert_eq!(e.pull(keep), 6);
    // the slots are reused: a new slab of the same size makes no new cells beyond them
    let s2 = e.slab(common::key("doc", &[1]));
    let y = e.state(s2, 0u32);
    assert_eq!(e.peek(y), 0);
}

/// A random graph of up to 200 cells under random writes: every pull equals a from-scratch evaluation.
#[derive(Clone, Debug)]
enum Op {
    /// a formula: the sum of its sources (cells made before it), times its factor, mod 1000
    Formula {
        srcs: Vec<usize>,
        factor: u64,
        branch: Option<usize>,
    },
}

fn graphs() -> impl Strategy<Value = (usize, Vec<Op>, Vec<(usize, u64)>)> {
    (1usize..20).prop_flat_map(|n_states| {
        let formulas = prop::collection::vec(
            (
                prop::collection::vec(any::<prop::sample::Index>(), 0..4),
                1u64..5,
                any::<Option<prop::sample::Index>>(),
            ),
            1..180,
        );
        let writes = prop::collection::vec((any::<prop::sample::Index>(), 0u64..4), 0..30);
        (Just(n_states), formulas, writes).prop_map(|(n, fs, ws)| {
            let mut ops = Vec::new();
            for (i, (srcs, factor, branch)) in fs.into_iter().enumerate() {
                let avail = n + i;
                ops.push(Op::Formula {
                    srcs: srcs.iter().map(|x| x.index(avail)).collect(),
                    factor,
                    branch: branch.map(|x| x.index(avail)),
                });
            }
            let ws = ws.into_iter().map(|(x, v)| (x.index(n), v)).collect();
            (n, ops, ws)
        })
    })
}

/// The from-scratch value of every cell given the states' values.
fn scratch(states: &[u64], ops: &[Op]) -> Vec<u64> {
    let mut v: Vec<u64> = states.to_vec();
    for op in ops {
        let Op::Formula {
            srcs,
            factor,
            branch,
        } = op;
        let take = branch.is_none_or(|b| v[b].is_multiple_of(2));
        let sum: u64 = if take {
            srcs.iter().map(|&s| v[s]).sum()
        } else {
            1
        };
        v.push(sum * factor % 1000);
    }
    v
}

#[derive(Clone, Copy)]
enum H {
    S(State<u64>),
    F(Formula<u64>),
}

impl H {
    fn get(self, r: &tafl::Rd) -> u64 {
        match self {
            H::S(s) => s.get(r),
            H::F(f) => f.get(r),
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 10_000, ..ProptestConfig::default() })]
    #[test]
    fn pull_equals_a_from_scratch_recompute((n, ops, writes) in graphs()) {
        let mut e = common::engine_light();
        let s = e.slab(common::key("doc", &[]));
        let mut states = vec![0u64; n];
        let mut hs: Vec<H> = (0..n).map(|_| H::S(e.state(s, 0u64))).collect();
        for op in &ops {
            let Op::Formula { srcs, factor, branch } = op.clone();
            let srcs: Vec<H> = srcs.iter().map(|&i| hs[i]).collect();
            let branch = branch.map(|b| hs[b]);
            let f = e.formula(s, Stage::Formula, move |r| {
                let take = branch.is_none_or(|b| b.get(r).is_multiple_of(2));
                let sum: u64 = if take { srcs.iter().map(|h| h.get(r)).sum() } else { 1 };
                sum * factor % 1000
            });
            hs.push(H::F(f));
        }
        for (i, (si, v)) in writes.iter().enumerate() {
            states[*si] = *v;
            let H::S(st) = hs[*si] else { unreachable!() };
            e.write(Origin::User, |w| st.set(w, *v));
            // pull a varying subset: cells not pulled stay marked and must still come out right later
            if i % 3 == 0 {
                continue;
            }
            let want = scratch(&states, &ops);
            for (j, h) in hs.iter().enumerate().skip(n).step_by(1 + i % 4) {
                let H::F(f) = h else { unreachable!() };
                prop_assert_eq!(e.pull(*f), want[j]);
            }
        }
        let want = scratch(&states, &ops);
        for (j, h) in hs.iter().enumerate().skip(n) {
            let H::F(f) = h else { unreachable!() };
            prop_assert_eq!(e.pull(*f), want[j]);
        }
    }
}

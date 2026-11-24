//! Collections: splices, versions and epochs, windows, and the incremental operators.

mod common;

use std::cell::Cell;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use tafl::{Engine, List, Monotone, Obj, Origin, Splice, Stage};

tafl::model! {
    pub struct Item { pub name: Arc<str>, pub rank: u64 }
}

/// N items named `item-i` with rank RANK(i), appended to L in one splice.
fn fill(e: &mut Engine, l: List<Item>, n: u64, rank: impl Fn(u64) -> u64) -> Vec<Obj<Item>> {
    e.write(Origin::Model, |w| {
        let objs: Vec<Obj<Item>> = (0..n)
            .map(|i| {
                w.insert(Item {
                    name: format!("item-{i}").into(),
                    rank: rank(i),
                })
            })
            .collect();
        l.splice(
            w,
            Splice::Insert {
                after: None,
                items: objs.iter().map(|o| o.model_ref()).collect(),
            },
        );
        objs
    })
}

fn count() -> Rc<Cell<u64>> {
    Rc::new(Cell::new(0))
}

/// One upstream insert becomes one downstream insert, with one predicate call: no full re-filter.
#[test]
fn filter_turns_a_splice_into_a_splice() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let l = e.list::<Item>();
    let objs = fill(&mut e, l, 100, |i| i);
    let calls = count();
    let even = {
        let c = calls.clone();
        l.filter(&mut e, move |o, r| {
            c.set(c.get() + 1);
            o.rank(r).is_multiple_of(2)
        })
    };
    let view = e.formula(s, Stage::Items, move |r| (even.len(r), even.version(r)));
    let (n, v0) = e.pull(view);
    assert_eq!(n, 50);
    assert_eq!(calls.get(), 100);
    let last = objs[99].key();
    e.write(Origin::Model, |w| {
        let o = w.insert(Item {
            name: "new".into(),
            rank: 200,
        });
        l.splice(
            w,
            Splice::Insert {
                after: Some(last),
                items: vec![o.model_ref()],
            },
        );
    });
    let (n, v1) = e.pull(view);
    assert_eq!(n, 51);
    assert_eq!(
        calls.get(),
        101,
        "an upstream insert re-filtered more than the new item"
    );
    assert_eq!(
        v1.0,
        v0.0 + 1,
        "one upstream splice made more than one downstream splice"
    );

    // a patch to one item's field re-evaluates that item only
    e.write(Origin::Model, |w| objs[2].update(w, |v| v.rank = 3));
    assert_eq!(e.pull(view).0, 50);
    assert_eq!(calls.get(), 102);
}

static REFINE_CALLS: AtomicUsize = AtomicUsize::new(0);

fn contains(it: &Item, q: &Arc<str>) -> bool {
    REFINE_CALLS.fetch_add(1, Ordering::SeqCst);
    it.name.contains(&**q)
}

/// A refined query (one more letter) on a monotone matcher filters the previous result only.
#[test]
fn a_refined_query_filters_the_previous_result_only() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let l = e.list::<Item>();
    fill(&mut e, l, 1000, |i| i);
    let q: tafl::State<Arc<str>> = e.state(s, Arc::from("1"));
    let shown = l.filter_by(
        &mut e,
        move |r| q.get(r),
        contains,
        Monotone::Yes(|old: &Arc<str>, new: &Arc<str>| new.contains(&**old)),
    );
    let n = e.formula(s, Stage::Items, move |r| shown.len(r));
    let first = e.pull(n);
    assert_eq!(REFINE_CALLS.load(Ordering::SeqCst), 1000);
    assert!(first > 0 && first < 1000);
    REFINE_CALLS.store(0, Ordering::SeqCst);
    e.write(Origin::User, |w| q.set(w, "12".into()));
    let second = e.pull(n);
    let calls = REFINE_CALLS.load(Ordering::SeqCst);
    assert!(
        calls <= first,
        "a refined query ran the predicate {calls} times over a previous result of {first}"
    );
    assert!(second <= first);
    let want = (0..1000)
        .filter(|i| format!("item-{i}").contains("12"))
        .count();
    assert_eq!(second, want);
}

static ON_POOL: AtomicBool = AtomicBool::new(false);
static ON_UI: AtomicBool = AtomicBool::new(false);

fn at_least(it: &Item, k: &u64) -> bool {
    if std::thread::current().name() == Some("saman-worker") {
        ON_POOL.store(true, Ordering::SeqCst);
    } else {
        ON_UI.store(true, Ordering::SeqCst);
    }
    it.rank >= *k
}

/// Over 10,000 items `filter_by` runs its predicate on the pool; until the result lands the old one stays, marked busy.
#[test]
fn filter_by_over_10k_runs_on_the_pool_and_keeps_the_old_result_busy() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let l = e.list::<Item>();
    fill(&mut e, l, 20_000, |i| i);
    let k = e.state(s, 15_000u64);
    let big = l.filter_by(&mut e, move |r| k.get(r), at_least, Monotone::No);
    let view = e.formula(s, Stage::Items, move |r| (big.len(r), big.busy(r)));
    assert_eq!(
        e.pull(view),
        (0, true),
        "the first result is not pending on the pool"
    );
    e.settle_blocking();
    assert_eq!(e.pull(view), (5_000, false));
    e.write(Origin::User, |w| k.set(w, 19_000));
    assert_eq!(
        e.pull(view),
        (5_000, true),
        "the old result was not kept while the new one is computed"
    );
    e.settle_blocking();
    assert_eq!(e.pull(view), (1_000, false));
    assert!(
        ON_POOL.load(Ordering::SeqCst),
        "the predicate never ran on the pool"
    );
    assert!(
        !ON_UI.load(Ordering::SeqCst),
        "the predicate ran on the UI thread over 10k items"
    );
}

thread_local! {
    static CMPS: Cell<u64> = const { Cell::new(0) };
}

/// A sort key that counts its comparisons.
#[derive(Clone, PartialEq, Eq, Debug)]
struct Counted(u64);

impl PartialOrd for Counted {
    fn partial_cmp(&self, o: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(o))
    }
}
impl Ord for Counted {
    fn cmp(&self, o: &Self) -> std::cmp::Ordering {
        CMPS.with(|c| c.set(c.get() + 1));
        self.0.cmp(&o.0)
    }
}

/// A changed key moves one item: one key computed, one downstream splice, a logarithmic number of comparisons.
#[test]
fn sort_moves_only_the_changed_item() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let l = e.list::<Item>();
    let n = 1024u64;
    let objs = fill(&mut e, l, n, |i| (n - i) * 2);
    let keys = count();
    let sorted = {
        let c = keys.clone();
        l.sort_by(&mut e, move |o, r| {
            c.set(c.get() + 1);
            Counted(o.rank(r))
        })
    };
    let view = e.formula(s, Stage::Items, move |r| {
        let w = sorted.window(r, 0..1024);
        let ranks: Vec<u64> = w.iter().map(|o| o.rank(r)).collect();
        (ranks, sorted.version(r))
    });
    let (ranks, v0) = e.pull(view);
    assert!(ranks.windows(2).all(|p| p[0] < p[1]), "not sorted");
    assert_eq!(keys.get(), n);
    keys.set(0);
    CMPS.with(|c| c.set(0));
    e.write(Origin::Model, |w| objs[10].update(w, |v| v.rank = 1));
    let (ranks, v1) = e.pull(view);
    assert_eq!(ranks[0], 1);
    assert!(
        ranks.windows(2).all(|p| p[0] < p[1]),
        "not sorted after the move"
    );
    assert_eq!(
        keys.get(),
        1,
        "more keys than the changed item's were computed"
    );
    assert_eq!(v1.0, v0.0 + 1, "a moved item made more than one splice");
    // one search to take the item out, one to put it in: each at most log2(n) + 1 comparisons
    let bound = 2 * (u64::from(n.ilog2()) + 1);
    let cmps = CMPS.with(Cell::get);
    assert!(
        cmps <= bound,
        "{cmps} comparisons to move one item in {n} (bound {bound})"
    );
}

/// `len` is maintained: reading it visits no item.
#[test]
fn len_is_maintained() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let l = e.list::<Item>();
    let objs = fill(&mut e, l, 1000, |i| i);
    let len = e.formula(s, Stage::Items, move |r| l.len(r));
    let visits = e.stats().item_visits;
    assert_eq!(e.pull(len), 1000);
    assert_eq!(e.stats().item_visits, visits, "reading len visited items");
    e.write(Origin::Model, |w| {
        l.splice(
            w,
            Splice::Remove {
                keys: vec![objs[3].key(), objs[7].key()],
            },
        )
    });
    let visits = e.stats().item_visits;
    assert_eq!(e.pull(len), 998);
    assert_eq!(e.stats().item_visits, visits, "reading len visited items");
}

/// Review Focus 3: a reader behind a trimmed splice log starts over once, then follows by splices again.
#[test]
fn a_trimmed_log_resets_the_reader_once() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let l = e.list::<Item>();
    fill(&mut e, l, 10, |i| i);
    let odd = l.filter(&mut e, |o, r| !o.rank(r).is_multiple_of(2));
    let len = e.formula(s, Stage::Items, move |r| odd.len(r));
    assert_eq!(e.pull(len), 5);
    let resets = e.stats().resets;
    for i in 0..1500u64 {
        e.write(Origin::Model, |w| {
            let o = w.insert(Item {
                name: "x".into(),
                rank: i,
            });
            l.splice(
                w,
                Splice::Insert {
                    after: None,
                    items: vec![o.model_ref()],
                },
            );
        });
    }
    assert_eq!(e.pull(len), 5 + 750);
    assert_eq!(
        e.stats().resets,
        resets + 1,
        "a reader behind a trimmed log did not start over exactly once"
    );
    e.write(Origin::Model, |w| {
        let o = w.insert(Item {
            name: "y".into(),
            rank: 1,
        });
        l.splice(
            w,
            Splice::Insert {
                after: None,
                items: vec![o.model_ref()],
            },
        );
    });
    assert_eq!(e.pull(len), 5 + 751);
    assert_eq!(
        e.stats().resets,
        resets + 1,
        "a reader started over with its log intact"
    );
}

/// A reset from an older epoch than the collection's is never applied (sja's epoch rule).
#[test]
fn an_old_epoch_is_never_applied() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let l = e.list::<Item>();
    e.write(Origin::Model, |w| {
        l.splice(w, Splice::Reset { total: 0, epoch: 2 })
    });
    fill(&mut e, l, 5, |i| i);
    let len = e.formula(s, Stage::Items, move |r| (l.len(r), l.version(r)));
    let (n, v) = e.pull(len);
    assert_eq!(n, 5);
    e.write(Origin::Model, |w| {
        l.splice(w, Splice::Reset { total: 0, epoch: 1 })
    });
    assert_eq!(e.pull(len), (5, v), "a reset of an old epoch was applied");
    e.write(Origin::Model, |w| {
        l.splice(w, Splice::Reset { total: 0, epoch: 3 })
    });
    assert_eq!(e.pull(len).0, 0);
}

/// A window of 60 over a million items runs the closures of those 60 only.
#[test]
fn window_runs_only_its_items() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let l = e.list::<Item>();
    fill(&mut e, l, 1_000_000, |i| i);
    let calls = count();
    let rows = {
        let c = calls.clone();
        e.formula(s, Stage::Items, move |r| {
            l.window(r, 500_000..500_060)
                .iter()
                .map(|o| {
                    c.set(c.get() + 1);
                    o.name(r)
                })
                .collect::<Vec<_>>()
        })
    };
    let visits = e.stats().item_visits;
    let names = e.pull(rows);
    assert_eq!(names.len(), 60);
    assert_eq!(&*names[0], "item-500000");
    assert_eq!(calls.get(), 60);
    assert!(
        e.stats().item_visits - visits <= 60,
        "the window visited items outside it"
    );
}

/// The hub's window arrives as splices: items that went are removed, new ones inserted, `total` and `from` taken.
#[test]
fn a_wire_window_becomes_splices() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let l = e.list::<Item>();
    let ids = ["a", "b", "c", "d", "e"];
    e.write(Origin::Model, |w| {
        for (i, id) in ids.iter().enumerate() {
            let o = w.insert(Item {
                name: (*id).into(),
                rank: i as u64,
            });
            tafl::wire::bind(w, Arc::from(*id), o);
        }
    });
    let msg = |names: &[&str], from: usize| sja::model::List {
        ids: names.iter().map(|n| Arc::from(*n)).collect(),
        total: Some(5),
        from,
    };
    e.write(Origin::Model, |w| {
        tafl::wire::apply(w, l, &msg(&["a", "b", "c"], 0))
    })
    .expect("a known window applies");
    let view = e.formula(s, Stage::Items, move |r| {
        let w = l.window(r, 0..5);
        (
            l.len(r),
            w.start,
            w.iter().map(|o| o.name(r).to_string()).collect::<Vec<_>>(),
        )
    });
    assert_eq!(
        e.pull(view),
        (5, 0, vec!["a".into(), "b".into(), "c".into()])
    );
    e.write(Origin::Model, |w| {
        tafl::wire::apply(w, l, &msg(&["b", "c", "d"], 1))
    })
    .expect("a moved window applies");
    assert_eq!(
        e.pull(view),
        (5, 1, vec!["b".into(), "c".into(), "d".into()])
    );
    let err = e.write(Origin::Model, |w| {
        tafl::wire::apply(w, l, &msg(&["b", "zz"], 1))
    });
    assert!(err.is_err(), "an unknown id was applied");
    assert_eq!(
        e.pull(view).2,
        vec!["b".to_string(), "c".into(), "d".into()],
        "a failed window changed the list"
    );
}

//! Early cutoff: a formula whose new value equals its old one leaves its dependents clean.

mod common;

use std::cell::Cell;
use std::rc::Rc;

use tafl::{Origin, Stage};

/// a → b → c, where b comes out the same after a changes: c is not re-run (its run count stays 1).
#[test]
fn cutoff_stops_at_an_equal_value() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let (nb, nc) = (Rc::new(Cell::new(0u32)), Rc::new(Cell::new(0u32)));
    let a = e.state(s, 2u32);
    let b = {
        let n = nb.clone();
        e.formula(s, Stage::Formula, move |r| {
            n.set(n.get() + 1);
            a.get(r) % 2
        })
    };
    let c = {
        let n = nc.clone();
        e.formula(s, Stage::Items, move |r| {
            n.set(n.get() + 1);
            format!("parity {}", b.get(r))
        })
    };
    assert_eq!(e.pull(c), "parity 0");
    e.write(Origin::User, |w| a.set(w, 4));
    assert_eq!(e.pull(c), "parity 0");
    assert_eq!(nb.get(), 2, "b was not re-run after its source changed");
    assert_eq!(nc.get(), 1, "c re-ran although b came out equal");
    e.write(Origin::User, |w| a.set(w, 5));
    assert_eq!(e.pull(c), "parity 1");
    assert_eq!(nc.get(), 2);
}

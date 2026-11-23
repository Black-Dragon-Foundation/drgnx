//! Review Focus 2: a formula that panics keeps its old value, its error is readable in place, the frame commits, and
//! the next write still propagates.

mod common;

use std::time::Duration;

use tafl::{Origin, Stage};

#[test]
fn a_panicking_formula_keeps_its_old_value_and_the_frame_commits() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let n = e.state(s, 1i32);
    let shown = e.formula(s, Stage::Formula, move |r| {
        let v = n.get(r);
        assert!(v >= 0, "negative count {v}");
        format!("{v} files")
    });
    let other = e.formula(s, Stage::Items, move |r| n.get(r) * 10);
    let label = e.formula(s, Stage::Items, move |r| format!("[{}]", shown.get(r)));
    let roots = [label.id(), other.id()];
    let out = e.frame(&roots, Duration::from_millis(4));
    assert_eq!(out.done.len(), 2);
    assert_eq!(e.pull(label), "[1 files]");

    e.write(Origin::User, |w| n.set(w, -3));
    let out = e.frame(&roots, Duration::from_millis(4));
    assert_eq!(
        out.done,
        roots.to_vec(),
        "the frame did not commit every root"
    );
    assert!(out.deferred.is_empty());
    assert_eq!(
        e.pull(shown),
        "1 files",
        "the panicking formula lost its old value"
    );
    assert_eq!(e.pull(label), "[1 files]");
    assert_eq!(
        e.pull(other),
        -30,
        "a sibling of the panicking formula did not update"
    );
    let err = e.error(shown.id()).expect("the error is readable in place");
    assert_eq!(err.cell, shown.id());
    assert!(err.message.contains("negative count -3"), "{}", err.message);

    e.write(Origin::User, |w| n.set(w, 7));
    e.frame(&roots, Duration::from_millis(4));
    assert_eq!(
        e.pull(label),
        "[7 files]",
        "the next write did not propagate"
    );
    assert!(
        e.error(shown.id()).is_none(),
        "the error outlived a good run"
    );
}

/// A formula whose first run panics has no value: `try_pull` gives its error, and a later good run gives the value.
#[test]
fn a_formula_that_never_ran_well_reports_its_error() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let n = e.state(s, 0u32);
    let f = e.formula(s, Stage::Formula, move |r| 100 / n.get(r));
    let err = e.try_pull(f).expect_err("a division by zero has no value");
    assert_eq!(err.cell, f.id());
    e.write(Origin::User, |w| n.set(w, 4));
    assert_eq!(e.try_pull(f), Ok(25));
}

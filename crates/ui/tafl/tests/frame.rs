//! Transactions and frames: writes coalesce into one frame; a frame over budget defers whole blocks.

mod common;

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use tafl::{Origin, Stage};

/// Three writes before a frame: one frame request, one marking pass each, one pull of the formula.
#[test]
fn writes_before_a_frame_coalesce() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let runs = Rc::new(Cell::new(0u32));
    let a = e.state(s, 0u32);
    let f = {
        let n = runs.clone();
        e.formula(s, Stage::Items, move |r| {
            n.set(n.get() + 1);
            a.get(r)
        })
    };
    e.frame(&[f.id()], Duration::from_millis(4));
    assert_eq!(runs.get(), 1);
    let before = e.stats();
    for v in 1..=3 {
        e.write(Origin::User, |w| a.set(w, v));
    }
    let after = e.stats();
    assert_eq!(
        after.frame_requests,
        before.frame_requests + 1,
        "three writes requested more than one frame"
    );
    assert_eq!(after.mark_passes, before.mark_passes + 3);
    assert!(!e.request_frame(), "a frame is already requested");
    let out = e.frame(&[f.id()], Duration::from_millis(4));
    assert_eq!(out.changed_items, vec![f.id()]);
    assert_eq!(
        runs.get(),
        2,
        "the formula ran more than once for three writes"
    );
    assert!(e.request_frame(), "the frame did not clear the request");
}

/// A frame whose budget runs out keeps the remaining blocks whole for the next frame.
#[test]
fn a_frame_over_budget_defers_whole_blocks() {
    let (sb, mut e) = common::engine();
    let s = e.slab(common::key("doc", &[]));
    let a = e.state(s, 0u32);
    let clock = sb.clock().clone();
    // each block costs 3 ms of (virtual) work
    let blocks: Vec<_> = (0..4u32)
        .map(|i| {
            let c = clock.clone();
            e.formula(s, Stage::Items, move |r| {
                c.advance(Duration::from_millis(3));
                a.get(r) + i
            })
        })
        .collect();
    let roots: Vec<_> = blocks.iter().map(|b| b.id()).collect();
    let out = e.frame(&roots, Duration::from_millis(4));
    assert_eq!(
        out.done,
        roots[..2].to_vec(),
        "the frame did not stop at its budget"
    );
    assert_eq!(out.deferred, roots[2..].to_vec());
    // the deferred blocks finish first in the next frame, each whole
    let out = e.frame(&roots[..1], Duration::from_millis(4));
    assert_eq!(out.done, roots[2..].to_vec());
    let out = e.frame(&roots[..1], Duration::from_millis(100));
    assert!(out.deferred.is_empty());
    for (i, b) in blocks.iter().enumerate() {
        assert_eq!(e.pull(*b), i as u32);
    }
}

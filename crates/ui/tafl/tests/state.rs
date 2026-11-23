//! The state table: state by name, outside the slabs.

mod common;

use std::sync::Arc;

use tafl::{Origin, StateKey};

fn sk(doc: &str, path: &[u32], name: &str) -> StateKey {
    StateKey {
        doc: Arc::from(doc),
        path: Arc::from(path),
        name: Arc::from(name),
    }
}

/// An instance dropped off screen and made again finds its state by name.
#[test]
fn dropped_instance_keeps_its_state_by_name() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[3]));
    let q = e.named_state(s, sk("files", &[3], "query"), String::new());
    e.write(Origin::User, |w| q.set(w, "main".into()));
    e.drop_slab(s);
    let s2 = e.slab(common::key("files", &[3]));
    let q2 = e.named_state(s2, sk("files", &[3], "query"), String::new());
    assert_eq!(e.peek(q2), "main");
    // another instance's state of the same name is its own
    let s3 = e.slab(common::key("files", &[4]));
    let q3 = e.named_state(s3, sk("files", &[4], "query"), String::new());
    assert_eq!(e.peek(q3), "");
}

/// Only values that differ from their initial value are stored.
#[test]
fn only_changed_states_are_stored() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let a = e.named_state(s, sk("files", &[], "a"), 1u32);
    let _b = e.named_state(s, sk("files", &[], "b"), 2u32);
    let c = e.named_state(s, sk("files", &[], "c"), 3u32);
    e.write(Origin::User, |w| {
        a.set(w, 10);
        c.set(w, 4);
        c.set(w, 3);
    });
    e.drop_slab(s);
    assert_eq!(
        e.stored_states(),
        1,
        "states equal to their initial value were stored"
    );
    let snap = e.snapshot_states();
    let s2 = e.slab(common::key("files", &[]));
    let a2 = e.named_state(s2, sk("files", &[], "a"), 1u32);
    assert_eq!(e.peek(a2), 10);
    // a warm restart: a fresh engine restores the snapshot and finds the state by name
    let (_sb2, mut f) = (0, common::engine_light());
    f.restore_states(snap);
    let s3 = f.slab(common::key("files", &[]));
    let a3 = f.named_state(s3, sk("files", &[], "a"), 1u32);
    assert_eq!(f.peek(a3), 10, "the warm restart lost the state");
}

/// A state whose type changed is reset to its new initial value, with one notice.
#[test]
fn a_type_change_resets_with_one_notice() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let q = e.named_state(s, sk("files", &[], "query"), String::from("x"));
    e.write(Origin::User, |w| q.set(w, "main".into()));
    e.drop_slab(s);
    assert!(e.take_notices().is_empty());
    let s2 = e.slab(common::key("files", &[]));
    let q2 = e.named_state(s2, sk("files", &[], "query"), 7u32);
    assert_eq!(e.peek(q2), 7);
    let notices = e.take_notices();
    assert_eq!(notices.len(), 1, "{notices:?}");
    assert!(notices[0].contains("query"), "{}", notices[0]);
    // the next instance has no stored state left to reset
    e.drop_slab(s2);
    let s3 = e.slab(common::key("files", &[]));
    let _q3 = e.named_state(s3, sk("files", &[], "query"), 7u32);
    assert!(e.take_notices().is_empty());
}

//! The ui-reactivity standard's conformance test (docs/develop/standards/ui-reactivity.md): the one reactive mechanism
//! for UI state drives a state, a formula, a model collection with a filter, a clock and a frame, with no callback,
//! observer, dependency list or channel anywhere.

mod common;

use std::sync::Arc;
use std::time::Duration;

use tafl::{Origin, Splice, Stage};

tafl::model! {
    pub struct File { pub name: Arc<str>, pub dir: Arc<str> }
}

#[test]
fn tafl_is_the_only_reactive_mechanism() {
    let (sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    // the document's state and model
    let query = e.state(s, String::new());
    let files = e.list::<File>();
    e.write(Origin::Model, |w| {
        let items = ["main.rs", "lib.rs", "engine.md"]
            .iter()
            .map(|n| {
                w.insert(File {
                    name: (*n).into(),
                    dir: "src".into(),
                })
                .model_ref()
            })
            .collect();
        files.splice(w, Splice::Insert { after: None, items });
    });
    // formulas: plain closures over handles, no dependency list
    let shown = files.filter(&mut e, move |f, r| {
        f.name(r).contains(query.get(r).as_str())
    });
    let minute = e.clock(Duration::from_secs(60));
    let status = e.formula(s, Stage::Items, move |r| {
        format!(
            "{} of {} files · {} min",
            shown.len(r),
            files.len(r),
            minute.get(r).as_secs() / 60
        )
    });
    let out = e.frame(&[status.id()], Duration::from_millis(4));
    assert_eq!(out.changed_items, vec![status.id()]);
    assert_eq!(e.pull(status), "3 of 3 files · 0 min");

    // an input writes state; the next frame carries it to the status line
    e.write(Origin::User, |w| query.set(w, ".rs".into()));
    assert!(!e.request_frame(), "the write did not request a frame");
    let out = e.frame(&[status.id()], Duration::from_millis(4));
    assert_eq!(out.changed_items, vec![status.id()]);
    assert_eq!(e.pull(status), "2 of 3 files · 0 min");

    // time is a cell: the minute passes, the status line follows
    sb.advance(Duration::from_secs(60));
    e.frame(&[status.id()], Duration::from_millis(4));
    assert_eq!(e.pull(status), "2 of 3 files · 1 min");

    // nothing changed: the frame changes nothing
    let out = e.frame(&[status.id()], Duration::from_millis(4));
    assert!(out.changed_items.is_empty());
    e.drop_slab(s);
    assert_eq!(sb.clock().sleepers(), 0);
}

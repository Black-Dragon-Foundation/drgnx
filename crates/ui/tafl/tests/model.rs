//! Model objects: a patch dirties only the readers of the fields it changed.

mod common;

use std::cell::Cell;
use std::rc::Rc;
use std::sync::Arc;

use tafl::{Model, Origin, Stage};

tafl::model! {
    /// A file as the Files pane shows it.
    pub struct File { pub name: Arc<str>, pub dir: Arc<str>, pub size: u64 }
}

/// A `name` patch re-runs no `dir` reader, and a `dir` patch re-runs no `name` reader.
#[test]
fn a_patch_dirties_only_readers_of_the_changed_field() {
    let (_sb, mut e) = common::engine();
    let s = e.slab(common::key("files", &[]));
    let f = e.write(Origin::Model, |w| {
        w.insert(File {
            name: "main.rs".into(),
            dir: "src".into(),
            size: 10,
        })
    });
    let (nn, nd) = (Rc::new(Cell::new(0u32)), Rc::new(Cell::new(0u32)));
    let name = {
        let n = nn.clone();
        e.formula(s, Stage::Items, move |r| {
            n.set(n.get() + 1);
            f.name(r)
        })
    };
    let dir = {
        let n = nd.clone();
        e.formula(s, Stage::Items, move |r| {
            n.set(n.get() + 1);
            format!("{}/", f.dir(r))
        })
    };
    assert_eq!(&*e.pull(name), "main.rs");
    assert_eq!(e.pull(dir), "src/");

    e.write(Origin::Model, |w| f.update(w, |v| v.name = "lib.rs".into()));
    assert_eq!(&*e.pull(name), "lib.rs");
    assert_eq!(e.pull(dir), "src/");
    assert_eq!(
        (nn.get(), nd.get()),
        (2, 1),
        "a name patch re-ran a dir reader"
    );

    e.write(Origin::Model, |w| f.update(w, |v| v.dir = "crates".into()));
    assert_eq!(e.pull(dir), "crates/");
    assert_eq!(&*e.pull(name), "lib.rs");
    assert_eq!(
        (nn.get(), nd.get()),
        (2, 2),
        "a dir patch re-ran a name reader"
    );

    // a patch that changes nothing marks nothing
    let marks = e.stats().marks;
    e.write(Origin::Model, |w| f.update(w, |v| v.size = 10));
    assert_eq!(e.stats().marks, marks);
}

/// The schema lists the fields in order; the readers are generated per field.
#[test]
fn the_schema_names_every_field() {
    let s = File::schema();
    assert_eq!(s.name, "File");
    let names: Vec<&str> = s.fields.iter().map(|f| f.name).collect();
    assert_eq!(names, ["name", "dir", "size"]);
    assert_eq!(File::TYPE, "File");
    assert_eq!(std::mem::size_of::<tafl::Obj<File>>(), 12);
    assert_eq!(std::mem::size_of::<tafl::State<u64>>(), 8);
}

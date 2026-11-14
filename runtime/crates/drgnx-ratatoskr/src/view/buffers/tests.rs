use super::*;
use runstav::methods::view::{Display, ViewEnv};

fn put(id: &str, name: &str, file: Option<&str>, modified: bool) -> BufferOp {
    BufferOp::Put {
        id: id.into(),
        name: name.into(),
        file: file.map(str::to_owned),
        modified,
    }
}

fn ids(set: &Set) -> Vec<String> {
    set.shown().into_iter().map(|b| b.id).collect()
}

fn env(display: Display, scale: f32) -> ViewEnv {
    ViewEnv {
        view: "buffers".into(),
        class: "c".into(),
        epoch: 1,
        display,
        scale,
        fonts: vec![],
        cell: (8, 16),
        width_px: 400,
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
        attach: false,
        rows_in_sja: false,
    }
}

/// The open order is the order ids were first put: a put of a known id (a rename, a save) keeps its place, a removed
/// one's place goes, and an id put again after its removal goes last.  A reset forgets every one.
#[test]
fn the_open_order_keeps_old_rows_and_appends_new_ones() {
    let mut s = Set::default();
    s.apply(vec![
        put("b1", "a", None, false),
        put("b2", "b", None, false),
        put("b3", "c", None, false),
    ]);
    s.apply(vec![put("b1", "renamed", None, true)]);
    assert_eq!(ids(&s), ["b1", "b2", "b3"]);
    assert_eq!(s.shown()[0].name, "renamed");
    assert!(s.shown()[0].modified);
    s.apply(vec![
        BufferOp::Remove { id: "b2".into() },
        put("b2", "b", None, false),
    ]);
    assert_eq!(ids(&s), ["b1", "b3", "b2"]);
    s.apply(vec![
        BufferOp::Modified {
            id: "b3".into(),
            modified: true,
        },
        BufferOp::Modified {
            id: "nope".into(),
            modified: true,
        },
    ]);
    assert!(s.shown()[1].modified);
    s.apply(vec![BufferOp::Reset, put("b9", "z", None, false)]);
    assert_eq!(ids(&s), ["b9"]);
}

/// The scope keeps the window's buffers in the open order (whatever order it names them in); the filter keeps names
/// that hold its text in any case; both at once keep what both let through; none or empty lets every one through.
#[test]
fn the_scope_and_the_filter_choose_the_rows() {
    let mut s = Set::default();
    s.apply(vec![
        put("b1", "Main.rs", None, false),
        put("b2", "notes.md", None, false),
        put("b3", "lib.rs", None, false),
    ]);
    s.apply(vec![BufferOp::Scope {
        ids: Some(vec!["b3".into(), "b1".into()]),
    }]);
    assert_eq!(ids(&s), ["b1", "b3"]);
    s.apply(vec![BufferOp::Filter {
        text: Some("MAIN".into()),
    }]);
    assert_eq!(ids(&s), ["b1"]);
    s.apply(vec![BufferOp::Scope { ids: None }]);
    s.apply(vec![BufferOp::Filter {
        text: Some(".R".into()),
    }]);
    assert_eq!(ids(&s), ["b1", "b3"]);
    s.apply(vec![BufferOp::Filter {
        text: Some(String::new()),
    }]);
    assert_eq!(ids(&s), ["b1", "b2", "b3"]);
}

/// A file's mark is its own status in the repository that holds it, else an ignored or untracked folder's around it;
/// a file outside every repository, or a repository whose root is only a prefix of its folder's name, has none.
#[test]
fn a_files_mark_is_its_repositorys() {
    let st = git::Status {
        files: BTreeMap::from([
            ("src/a.rs".to_owned(), git::Kind::Modified),
            ("target".to_owned(), git::Kind::Ignored),
        ]),
        branch: None,
    };
    let statuses = vec![(PathBuf::from("/r"), Arc::new(st))];
    assert_eq!(mark_of("/r/src/a.rs", &statuses), Some(git::Kind::Modified));
    assert_eq!(
        mark_of("/r/target/x/y.o", &statuses),
        Some(git::Kind::Ignored)
    );
    assert_eq!(mark_of("/r/src/b.rs", &statuses), None);
    assert_eq!(mark_of("/rx/src/a.rs", &statuses), None);
    assert_eq!(mark_of("/elsewhere/a.rs", &statuses), None);
}

/// Pattern D, the Open list's look on the hub's rows: on a terminal two characters of room, then the name; on a
/// graphical display a space, the file's icon with 6 px either side (device px at the env's scale) as the Explorer's
/// top files.  A control character in a name shows as ^X.  The git status and the unsaved flag ride on the name, an
/// ignored name is dimmed instead, the id is over the row.
#[test]
fn buffer_rows_draw_the_look() {
    let st = git::Status {
        files: BTreeMap::from([
            ("a.rs".to_owned(), git::Kind::Modified),
            ("out.log".to_owned(), git::Kind::Ignored),
        ]),
        branch: None,
    };
    let statuses = vec![(PathBuf::from("/r"), Arc::new(st))];
    let shown = vec![
        Buf {
            id: "b1".into(),
            name: "a.rs".into(),
            file: Some("/r/a.rs".into()),
            modified: true,
        },
        Buf {
            id: "b2".into(),
            name: "out.log".into(),
            file: Some("/r/out.log".into()),
            modified: false,
        },
        Buf {
            id: "b3".into(),
            name: "x\ny".into(),
            file: None,
            modified: false,
        },
    ];
    let look = RowLook::of(&env(Display::Tty, 1.0), INDENT, 1);
    let (rows, images) = buffer_rows(&shown, &statuses, &look);
    assert!(images.is_empty());
    assert_eq!(rows[0].text, "  a.rs");
    assert_eq!(
        rows[0].props,
        vec![
            (2, 6, "drgnx-git-status".into(), json!("modified")),
            (2, 6, "drgnx-buffers-modified".into(), json!(true)),
            (0, 6, "drgnx-work-id".into(), json!("b1")),
        ]
    );
    assert!(rows[0].runs.is_empty());
    assert_eq!(rows[1].runs, vec![(2, 9, "drgnx-git-ignored".into())]);
    assert_eq!(
        rows[1].props,
        vec![(0, 9, "drgnx-work-id".into(), json!("b2"))]
    );
    assert_eq!(rows[2].text, "  x^Jy");

    let look = RowLook::of(&env(Display::Gui, 2.0), INDENT, 1);
    let (rows, images) = buffer_rows(&shown, &statuses, &look);
    let r = &rows[0];
    assert_eq!(r.text, "    a.rs");
    assert_eq!(r.spaces, vec![(1, 12, 32), (3, 12, 32)]);
    assert_eq!(r.images.len(), 1);
    assert_eq!(r.images[0].0, 2);
    assert!(images.iter().any(|(id, _)| *id == r.images[0].1));
    assert_eq!(
        r.props[0],
        (4, 8, "drgnx-git-status".into(), json!("modified"))
    );
    // each icon goes once, however many rows name it
    let ids: HashSet<_> = images.iter().map(|(id, _)| *id).collect();
    assert_eq!(ids.len(), images.len());
}

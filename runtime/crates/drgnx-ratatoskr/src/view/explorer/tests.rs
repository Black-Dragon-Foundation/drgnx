use super::*;
use std::collections::HashMap;

/// A fake disk: folder → its sorted entries; READS counts each folder read.
fn disk() -> HashMap<String, Vec<(String, bool)>> {
    let e = |n: &str, d: bool| (n.to_owned(), d);
    HashMap::from([
        (
            "/r".into(),
            vec![e("a", true), e("lib", true), e("z.txt", false)],
        ),
        ("/r/a".into(), vec![e("b", true)]),
        ("/r/a/b".into(), vec![e("c", true)]),
        ("/r/a/b/c".into(), vec![e("x.rs", false)]),
        ("/r/lib".into(), vec![e("m.el", false)]),
    ])
}

fn list(expanded: &[&str], compact: bool, reads: &mut Vec<String>) -> Option<Vec<Entry>> {
    let d = disk();
    let expanded: HashSet<String> = expanded.iter().map(|s| (*s).to_owned()).collect();
    let mut read = |p: &Path| {
        let p = p.to_string_lossy().into_owned();
        reads.push(p.clone());
        d.get(&p).cloned().unwrap_or_default()
    };
    list_tree(
        &[PathBuf::from("/r/")],
        &expanded,
        compact,
        &AtomicBool::new(false),
        &mut read,
    )
}

/// Pattern D: a folder lists its folders first, then its files, each in natural case-insensitive order (file2
/// before file10), and leaves out a version-control folder, `__pycache__`, `.DS_Store` and `.#…` locks.
#[test]
fn explorer_lists_folders_first_in_natural_order() {
    let dir = tempfile::tempdir().unwrap();
    for f in ["file10", "File2", ".#lock", ".DS_Store", "b.txt"] {
        std::fs::write(dir.path().join(f), "x").unwrap();
    }
    for d in ["Zed", "alpha", ".git", "__pycache__"] {
        std::fs::create_dir(dir.path().join(d)).unwrap();
    }
    std::os::unix::fs::symlink(dir.path().join("alpha"), dir.path().join("link")).unwrap();
    let got = read_folder(dir.path(), &Exclude::default());
    let want: Vec<(String, bool)> = [
        ("alpha", true),
        ("link", true),
        ("Zed", true),
        ("b.txt", false),
        ("File2", false),
        ("file10", false),
    ]
    .iter()
    .map(|(n, d)| ((*n).to_owned(), *d))
    .collect();
    assert_eq!(got, want);
    assert_eq!(natural("a9", "a10"), Cmp::Less);
    assert_eq!(natural("A01", "a1"), Cmp::Equal);
}

/// Pattern D: only the roots and the open folders are read; an open folder whose only entry is a folder joins it on
/// one row up to the first closed folder (never read), whose node is the row's; COMPACT off keeps one row each.
#[test]
fn explorer_tree_joins_open_chains() {
    let mut reads = Vec::new();
    let got = list(&["/r/a", "/r/a/b"], true, &mut reads).unwrap();
    let shown: Vec<(&str, &str, usize, bool)> = got
        .iter()
        .map(|e| (e.path.as_str(), e.label.as_str(), e.depth, e.open))
        .collect();
    assert_eq!(
        shown,
        vec![
            ("/r", "R", 0, true),
            ("/r/a/b/c", "a/b/c", 1, false),
            ("/r/lib", "lib", 1, false),
            ("/r/z.txt", "z.txt", 1, false),
        ]
    );
    assert_eq!(reads, vec!["/r", "/r/a", "/r/a/b"]);
    assert_eq!(got[1].parent.as_deref(), Some("/r"));

    let mut reads = Vec::new();
    let got = list(&["/r/a", "/r/lib"], false, &mut reads).unwrap();
    let shown: Vec<(&str, usize, Option<&str>)> = got
        .iter()
        .map(|e| (e.label.as_str(), e.depth, e.parent.as_deref()))
        .collect();
    assert_eq!(
        shown,
        vec![
            ("R", 0, None),
            ("a", 1, Some("/r")),
            ("b", 2, Some("/r/a")),
            ("lib", 1, Some("/r")),
            ("m.el", 2, Some("/r/lib")),
            ("z.txt", 1, Some("/r")),
        ]
    );

    let cancel = AtomicBool::new(true);
    let d = disk();
    let mut read = |p: &Path| d.get(&*p.to_string_lossy()).cloned().unwrap_or_default();
    assert!(
        list_tree(
            &[PathBuf::from("/r")],
            &HashSet::new(),
            true,
            &cancel,
            &mut read
        )
        .is_none()
    );
}

/// Pattern D: the model is a `tree` of path nodes in pre-order (an open folder flagged `expanded`, each entry's parent
/// the entry above it), and each row is the guides and chevron, then the name, the path over the whole row.
#[test]
fn explorer_model_and_rows() {
    let mut reads = Vec::new();
    let got = list(&["/r/lib"], true, &mut reads).unwrap();
    let doc = explorer_doc_in(&got, MODEL_WINDOW, None);
    assert_eq!(doc.descriptor["scheme"], "tree");
    assert_eq!(
        doc.lists["order"],
        vec!["/r", "/r/a", "/r/lib", "/r/lib/m.el", "/r/z.txt"]
    );
    assert_eq!(doc.nodes["/r"]["kind"], "root");
    assert_eq!(doc.nodes["/r/lib"]["flags"], 1);
    assert_eq!(doc.nodes["/r/a"]["flags"], 0);
    assert_eq!(doc.nodes["/r/lib/m.el"]["parent"], "/r/lib");
    assert_eq!(doc.nodes["/r/lib/m.el"]["kind"], "file");
    assert!(doc.nodes["/r"].get("parent").is_none());
    assert!(doc.windows.is_empty());

    let tty = RowLook {
        gui: None,
        one_root: false,
    };
    let (rows, images) = explorer_rows(&got, &Decor::default(), &tty);
    assert!(images.is_empty());
    let texts: Vec<&str> = rows.iter().map(|r| r.text.as_str()).collect();
    assert_eq!(texts, vec!["▾ R", "▸ a", "▾ lib", "│   m.el", "  z.txt"]);
    let m = &rows[3];
    assert_eq!(m.key, "/r/lib/m.el");
    assert_eq!(
        m.props,
        vec![(0, 8, "drgnx-work-id".to_owned(), json!("/r/lib/m.el"))]
    );
    assert_eq!(m.runs[0], (0, 4, "drgnx-explorer-guide".to_owned()));
    assert_eq!(m.runs[1], (4, 8, "drgnx-explorer-file".to_owned()));

    let cut = explorer_doc_in(&got, 2, None);
    assert_eq!(cut.lists["order"].len(), 2);
    assert_eq!(cut.windows["order"], (5, 0));
    // a window from the fourth entry: m.el and z.txt, with m.el's folders as nodes (not in `order`)
    let late = explorer_doc_in(&got, 2, Some(3));
    assert_eq!(late.lists["order"], ["/r/lib/m.el", "/r/z.txt"]);
    assert_eq!(late.windows["order"], (5, 3));
    assert!(late.nodes.contains_key("/r/lib"));
    assert!(late.nodes.contains_key(&got[0].path), "the root");
    assert_eq!(display("a\nb\u{7f}"), "a^Jb^?");
}

/// The next listing the watching thread handed over within SECS, or none.
fn entry(path: &str, depth: usize, dir: bool, open: bool) -> Entry {
    let label = path.rsplit('/').next().unwrap_or(path).to_owned();
    Entry {
        path: path.into(),
        parent: path
            .rsplit_once('/')
            .map(|(p, _)| p.to_owned())
            .filter(|_| depth > 0),
        label: if depth == 0 {
            label.to_uppercase()
        } else {
            label
        },
        depth,
        dir,
        open,
    }
}

fn gui_env(scale: f32) -> ViewEnv {
    ViewEnv {
        view: "x".into(),
        class: "c".into(),
        epoch: 1,
        display: Display::Gui,
        scale,
        fonts: vec![],
        cell: (8, 16),
        width_px: 400,
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
        attach: false,
    }
}

/// Pattern D, the look-fix layout on the hub's rows (plan sja-complete E2): on a graphical display a level's indent is
/// a space of `tree-indent` device px, a folder's chevron and every icon are images (each sent once), the icon has
/// 6 px either side, then the name; the git status rides on the name (a folder's is the strongest inside it), an
/// ignored name is dimmed, who is here rides on the name as ordinals, and a single root's row is invisible.  Sizes are device px at the env's scale.
#[test]
fn explorer_rows_draw_the_look() {
    let entries = vec![
        entry("/r", 0, true, true),
        entry("/r/src", 1, true, true),
        entry("/r/src/a.rs", 2, false, false),
        entry("/r/target", 1, true, false),
        entry("/r/notes.md", 1, false, false),
    ];
    let status = git::Status {
        files: BTreeMap::from([
            ("src/a.rs".to_owned(), git::Kind::Modified),
            ("target".to_owned(), git::Kind::Ignored),
        ]),
        branch: None,
    };
    let here: Here = BTreeMap::from([
        ("/r/src".to_owned(), BTreeSet::from([1, 3])),
        ("/r/src/a.rs".to_owned(), BTreeSet::from([3])),
    ]);
    let decor = Decor {
        git: marks_of(&entries, &[(PathBuf::from("/r/"), Arc::new(status))]),
        here: Arc::new(here),
    };
    let look = RowLook::of(&gui_env(2.0), 12, 1);
    assert_eq!(look.gui, Some((24, 32, 12)));
    let (rows, images) = explorer_rows(&entries, &decor, &look);
    let id = |name: &str| icons::svg(name, 32).unwrap().0;
    let prop = |r: &Row, name: &str| r.props.iter().find(|p| p.2 == name).cloned();

    // the root: invisible, as the only root
    assert_eq!(prop(&rows[0], "invisible").map(|p| p.3), Some(json!(true)));
    // src: chevron (open), gap, folder-open, gap, the name; changes inside it
    let src = &rows[1];
    assert_eq!(src.text, "    src");
    assert_eq!(
        src.images,
        vec![
            (0, id("chevron-down"), "▾".to_owned()),
            (2, id("folder-open"), " ".to_owned())
        ]
    );
    assert_eq!(src.spaces, vec![(1, 12, 32), (3, 12, 32)]);
    assert_eq!(
        prop(src, "drgnx-git-status"),
        Some((4, 7, "drgnx-git-status".to_owned(), json!("modified")))
    );
    // a.rs: one indent, no chevron, the code icon; modified
    let a = &rows[2];
    assert_eq!(a.text, "     a.rs");
    assert_eq!(a.spaces, vec![(0, 24, 32), (2, 12, 32), (4, 12, 32)]);
    assert_eq!(a.images, vec![(3, id("file-code"), " ".to_owned())]);
    assert!(a.runs.contains(&(5, 9, "drgnx-explorer-file".to_owned())));
    assert!(a.runs.contains(&(1, 5, "drgnx-explorer-guide".to_owned())));
    assert_eq!(
        prop(a, "drgnx-git-status").map(|p| p.3),
        Some(json!("modified"))
    );
    // who is here: the agents' ordinals over the name, none where nobody is
    assert_eq!(
        prop(src, "drgnx-agents-here"),
        Some((4, 7, "drgnx-agents-here".to_owned(), json!([1, 3])))
    );
    assert_eq!(prop(a, "drgnx-agents-here").map(|p| p.3), Some(json!([3])));
    assert_eq!(prop(&rows[4], "drgnx-agents-here"), None);
    // target: ignored, dimmed, no mark
    let t = &rows[3];
    assert!(t.runs.iter().any(|r| r.2 == "drgnx-git-ignored"));
    assert_eq!(prop(t, "drgnx-git-status"), None);
    assert_eq!(t.images[0].1, id("chevron-right"));
    // notes.md: clean, the text icon
    assert_eq!(prop(&rows[4], "drgnx-git-status"), None);
    assert_eq!(rows[4].images[0].1, id("file-text"));
    // each icon once
    let mut ids: Vec<ImageId> = images.iter().map(|i| i.0).collect();
    ids.dedup();
    assert_eq!(ids.len(), 6);
    assert_eq!(images.len(), 6);
    // two roots: both rows show
    let two = RowLook::of(&gui_env(1.0), 14, 2);
    assert_eq!(two.gui, Some((14, 16, 6)));
    let (rows, _) = explorer_rows(&entries, &decor, &two);
    assert_eq!(prop(&rows[0], "invisible"), None);
}

/// Pattern D: an untracked or ignored folder's entries take its status (git lists the folder, not what is in it).
#[test]
fn explorer_marks_inherit_from_untracked_and_ignored_folders() {
    let entries = vec![
        entry("/r", 0, true, true),
        entry("/r/new", 1, true, true),
        entry("/r/new/x.rs", 2, false, false),
        entry("/r/out", 1, true, true),
        entry("/r/out/y.o", 2, false, false),
    ];
    let status = git::Status {
        files: BTreeMap::from([
            ("new".to_owned(), git::Kind::Untracked),
            ("out".to_owned(), git::Kind::Ignored),
        ]),
        branch: None,
    };
    let marks = marks_of(&entries, &[(PathBuf::from("/r"), Arc::new(status))]);
    assert_eq!(marks["/r/new"], git::Kind::Untracked);
    assert_eq!(marks["/r/new/x.rs"], git::Kind::Untracked);
    assert_eq!(marks["/r/out/y.o"], git::Kind::Ignored);
    assert_eq!(
        marks["/r"],
        git::Kind::Added,
        "the root rolls up the untracked folder as added"
    );
}

fn next_listing(got: &std::sync::mpsc::Receiver<Vec<Entry>>, secs: f32) -> Option<Vec<String>> {
    got.recv_timeout(std::time::Duration::from_secs_f32(secs))
        .ok()
        .map(|es| es.into_iter().map(|e| e.path).collect())
}

/// Pattern C (a gate on the first listing, then on each relisting): a listing's thread watches the folders it read.
/// A file made in an open folder, then removed, each relists (the new listing holds it, then does not) with no new
/// subscribe; a change in a closed folder sends nothing; `Heard::Stop` ends the thread, which drops the watcher.
#[test]
fn explorer_watch_relists_open_folders_only() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("w");
    std::fs::create_dir_all(root.join("open")).unwrap();
    std::fs::create_dir_all(root.join("shut")).unwrap();
    let id = |p: &Path| p.to_string_lossy().into_owned();
    let expanded: HashSet<String> = [id(&root.join("open"))].into();
    let (tx, rx) = std::sync::mpsc::channel();
    let (out, got) = std::sync::mpsc::channel();
    let roots = vec![root.clone()];
    let stop = tx.clone();
    let listing = |id: u64, expanded: HashSet<String>| Listing {
        id,
        roots: roots.clone(),
        expanded,
        compact: false,
        exclude: Exclude::default(),
    };
    let first = listing(1, expanded.clone());
    let (id_out, ids) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        let cancel = AtomicBool::new(false);
        list_and_watch(first, &cancel, (tx, rx), &mut |l, es, _| {
            id_out.send(l.id).is_ok() && out.send(es).is_ok()
        });
    });
    let first = next_listing(&got, 10.0).expect("the first listing");
    assert_eq!(
        first,
        [id(&root), id(&root.join("open")), id(&root.join("shut"))]
    );

    let new = root.join("open").join("new.txt");
    std::fs::write(&new, "x").unwrap();
    let after = next_listing(&got, 5.0).expect("a relisting after the file was made");
    assert!(after.contains(&id(&new)), "{after:?}");

    std::fs::remove_file(&new).unwrap();
    let gone = next_listing(&got, 5.0).expect("a relisting after the file went");
    assert!(!gone.contains(&id(&new)), "{gone:?}");

    std::fs::write(root.join("shut").join("hidden.txt"), "x").unwrap();
    assert_eq!(
        next_listing(&got, 0.5),
        None,
        "a closed folder's change sends nothing"
    );

    // a new subscribe of the same view: the same thread lists again with shut/ open (no watch gap), then watches it
    let both: HashSet<String> = [id(&root.join("open")), id(&root.join("shut"))].into();
    stop.send(Heard::Relist(Box::new(listing(2, both))))
        .unwrap();
    let relisted = next_listing(&got, 5.0).expect("the relisting");
    assert!(
        relisted.contains(&id(&root.join("shut").join("hidden.txt"))),
        "{relisted:?}"
    );
    assert_eq!(ids.try_iter().last(), Some(2), "sent as listing 2");
    let more = root.join("shut").join("more.txt");
    std::fs::write(&more, "x").unwrap();
    let seen = next_listing(&got, 5.0).expect("a change in the folder the relisting opened");
    assert!(seen.contains(&id(&more)), "{seen:?}");

    stop.send(Heard::Stop).unwrap();
    let t0 = std::time::Instant::now();
    thread.join().unwrap();
    assert!(t0.elapsed() < std::time::Duration::from_secs(2));
}

/// Pattern D (plan sja-complete E3, Q4): `exclude` takes names and globs (`*`, `?`), replacing the default set.
#[test]
fn exclude_takes_names_and_globs() {
    let d = Exclude::default();
    for n in [".git", ".DS_Store", "__pycache__", ".#init.el"] {
        assert!(d.matches(n), "{n}");
    }
    for n in ["git", "src", "a.git", ".gitignore"] {
        assert!(!d.matches(n), "{n}");
    }
    let e = Exclude::new(vec!["*.o".into(), "node_modules".into(), "?.tmp".into()]);
    assert!(e.matches("main.o") && e.matches("node_modules") && e.matches("a.tmp"));
    assert!(!e.matches("main.oo") && !e.matches("ab.tmp") && !e.matches(".git"));
    let dir = tempfile::tempdir().unwrap();
    for f in ["main.o", "main.c", ".DS_Store"] {
        std::fs::write(dir.path().join(f), "x").unwrap();
    }
    let names = |e: &Exclude| -> Vec<String> {
        read_folder(dir.path(), e)
            .into_iter()
            .map(|(n, _)| n)
            .collect()
    };
    assert_eq!(names(&e), [".DS_Store", "main.c"]);
    assert_eq!(names(&Exclude::default()), ["main.c", "main.o"]);
}

/// Pattern D (plan sja-complete E3): Find lists only the files it found, each with every folder above it open, in the
/// listing's order; a file under no root is left out.
#[test]
fn find_lists_only_the_found_files() {
    let roots = [PathBuf::from("/r")];
    let files: Vec<PathBuf> = ["/r/src/b.rs", "/r/src/a/x.rs", "/r/top.md", "/elsewhere/y"]
        .iter()
        .map(PathBuf::from)
        .collect();
    let (kids, open) = only_tree(&roots, &files);
    let got = list_tree(&roots, &open, false, &AtomicBool::new(false), &mut |d| {
        kids.get(d).cloned().unwrap_or_default()
    })
    .unwrap();
    let paths: Vec<&str> = got.iter().map(|e| e.path.as_str()).collect();
    assert_eq!(
        paths,
        [
            "/r",
            "/r/src",
            "/r/src/a",
            "/r/src/a/x.rs",
            "/r/src/b.rs",
            "/r/top.md"
        ]
    );
    assert!(got.iter().filter(|e| e.dir).all(|e| e.open));
}

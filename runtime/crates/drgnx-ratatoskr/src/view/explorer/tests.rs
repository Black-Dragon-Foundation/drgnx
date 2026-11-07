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
    let got = read_folder(dir.path());
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
    let doc = explorer_doc(&got);
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

    let rows = explorer_rows(&got);
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

    let cut = explorer_doc_in(&got, 2);
    assert_eq!(cut.lists["order"].len(), 2);
    assert_eq!(cut.windows["order"], (5, 0));
    assert_eq!(display("a\nb\u{7f}"), "a^Jb^?");
}

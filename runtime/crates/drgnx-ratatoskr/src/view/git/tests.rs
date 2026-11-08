use super::*;

fn files(pairs: &[(&str, Kind)]) -> BTreeMap<String, Kind> {
    pairs.iter().map(|(p, k)| ((*p).to_owned(), *k)).collect()
}

fn set(xs: &[&str]) -> BTreeSet<String> {
    xs.iter().map(|x| (*x).to_owned()).collect()
}

#[test]
fn porcelain_v2_parse() {
    let out = [
        "# branch.oid 1234",
        "# branch.head main",
        "# branch.upstream origin/main",
        "# branch.ab +2 -1",
        "1 .M N... 100644 100644 100644 aaaa bbbb src/a b.rs",
        "1 D. N... 100644 000000 000000 aaaa 0000 gone.rs",
        "1 A. N... 000000 100644 100644 0000 bbbb new.rs",
        "2 R. N... 100644 100644 100644 aaaa bbbb R100 renamed.rs",
        "old name.rs",
        "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc clash.rs",
        "? scratch/",
        "! target/",
    ]
    .join("\0")
        + "\0";
    let st = parse(out.as_bytes(), IGNORED_LIMIT);
    assert_eq!(
        st.files,
        files(&[
            ("src/a b.rs", Kind::Modified),
            ("gone.rs", Kind::Deleted),
            ("new.rs", Kind::Added),
            ("renamed.rs", Kind::Renamed),
            ("clash.rs", Kind::Conflict),
            ("scratch", Kind::Untracked),
            ("target", Kind::Ignored),
        ])
    );
    assert_eq!(
        st.branch,
        Some(Branch {
            head: Some("main".into()),
            ahead: Some(2),
            behind: Some(1)
        })
    );
    let detached = parse(b"# branch.head (detached)\0", 0);
    assert_eq!(detached.branch.unwrap().head, None);
}

#[test]
fn ignored_entries_not_listed() {
    let out = "? a\0! x/\0! y/\0! z/\0";
    let few = parse(out.as_bytes(), 3);
    assert_eq!(few.files.len(), 4);
    let many = parse(out.as_bytes(), 2);
    assert_eq!(many.files, files(&[("a", Kind::Untracked)]));
}

#[test]
fn rollup_only_for_shown_folders() {
    let f = files(&[
        ("a/b/c.rs", Kind::Modified),
        ("a/d.rs", Kind::Deleted),
        ("a/e/new.rs", Kind::Untracked),
        ("z/q.rs", Kind::Added),
        ("a/log", Kind::Ignored),
        ("top.rs", Kind::Modified),
    ]);
    let r = rollup(&f, &set(&["a", "a/e"]));
    // the root and the shown folders only; the strongest status inside; untracked counts as added; ignored not at all
    assert_eq!(
        r,
        files(&[
            (".", Kind::Deleted),
            ("a", Kind::Deleted),
            ("a/e", Kind::Added)
        ])
    );
    assert!(!r.contains_key("a/b"));
    assert!(!r.contains_key("z"));
    let keys: Vec<String> = rows(
        &Status {
            files: f,
            branch: None,
        },
        &set(&["a"]),
    )
    .into_iter()
    .map(|r| r.key)
    .collect();
    assert!(keys.contains(&"d:a".to_owned()) && keys.contains(&"d:.".to_owned()));
    assert!(!keys.contains(&"d:z".to_owned()));
}

#[test]
fn letters_are_rows_with_their_faces() {
    let r = file_row("x.rs", Kind::Modified);
    assert_eq!((r.key.as_str(), r.text.as_str()), ("f:x.rs", "M"));
    assert_eq!(r.runs, vec![(0, 1, "drgnx-git-modified".to_owned())]);
    assert_eq!(r.props[0].2, "drgnx-git-status");
    assert_eq!(folder_row("a", Kind::Added).text, "●");
}

#[test]
fn a_root_that_is_no_repository_is_an_error_not_no_changes() {
    let dir = std::env::temp_dir().join(format!("letters-norepo-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let err = read_status(&dir).expect_err("git status of a folder outside any repository fails");
    assert!(!err.is_empty());
    let ev = error_event("v", &dir, &err);
    assert_eq!(ev["view"], "v");
    assert_eq!(ev["root"], dir.to_string_lossy().as_ref());
    assert_eq!(ev["error"], err);
    std::fs::remove_dir_all(&dir).unwrap();
}

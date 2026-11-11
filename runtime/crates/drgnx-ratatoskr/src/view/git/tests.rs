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

fn git(dir: &std::path::Path, args: &[&str]) {
    let ok = Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .current_dir(dir)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(ok, "git {args:?}");
}

/// Pattern D (plan sja-complete E3, the coordinator's ruling): a repository's watch reads its status again when git
/// changes it from anywhere (an add, a commit, a checkout in a terminal), once per burst, and when poked (a name made
/// outside git); its own reads (`git status`) are no change; a linked worktree's gitdir is found; it ends on Stop.
#[test]
fn a_repository_s_watch_reads_again_after_git_changes_it() {
    let dir = std::env::temp_dir().join(format!("letters-watch-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    git(&dir, &["init", "-q"]);
    std::fs::write(dir.join("a"), "1").unwrap();
    git(&dir, &["add", "a"]);
    git(&dir, &["commit", "-qm", "one"]);
    let (tx, rx) = channel();
    let (reads_tx, reads) = channel();
    let (root, poke) = (dir.clone(), tx.clone());
    let watch = std::thread::spawn(move || {
        watch_repo(&root, tx, rx, &mut || {
            // what the hub's read does: a status read, which must not count as a change
            let _ = read_status(&root);
            reads_tx.send(()).is_ok()
        });
    });
    // the watch is set once a change in the gitdir is read; then the probe's burst is drained
    skuld::wait_until("the watch is set", 10, || {
        std::fs::write(dir.join(".git").join("description"), "probe\n").unwrap();
        reads.recv_timeout(Duration::from_millis(50)).ok()
    });
    while reads.recv_timeout(Duration::from_millis(600)).is_ok() {}
    let next = |what: &str| {
        reads
            .recv_timeout(Duration::from_secs(5))
            .unwrap_or_else(|_| panic!("no read after {what}"));
        // the burst is read once, and the read itself wakes nothing
        assert!(
            reads.recv_timeout(Duration::from_millis(600)).is_err(),
            "one read per burst ({what})"
        );
    };
    std::fs::write(dir.join("b"), "2").unwrap();
    git(&dir, &["add", "b"]);
    next("git add");
    git(&dir, &["commit", "-qm", "two"]);
    next("git commit");
    git(&dir, &["checkout", "-qb", "side"]);
    next("git checkout");
    poke.send(Heard::Changed).unwrap();
    next("a poke");
    // a linked worktree: its gitdir and the common dir
    let wt = dir.join("wt");
    git(
        &dir,
        &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "wtb"],
    );
    let (gitdir, common) = git_dirs(&wt).expect("a linked worktree's dirs");
    assert!(gitdir.join("HEAD").is_file(), "{gitdir:?}");
    assert_eq!(
        common.canonicalize().unwrap(),
        dir.join(".git").canonicalize().unwrap()
    );
    let _ = reads.recv_timeout(Duration::from_secs(2)); // the worktree add moved refs: one read
    poke.send(Heard::Stop).unwrap();
    watch.join().unwrap();
    assert!(git_dirs(&dir.join("a")).is_none());
    std::fs::remove_dir_all(&dir).unwrap();
}

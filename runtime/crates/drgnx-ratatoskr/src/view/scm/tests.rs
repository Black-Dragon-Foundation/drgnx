use super::*;
use std::process::Command;

/// Run the shell SCRIPT in DIR (a fresh repository's git config names its author), panicking on failure.
fn sh(dir: &Path, script: &str) {
    let out = Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_WORK_TREE")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{script}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A repository in a new folder of TMP called NAME with one commit of a.txt and b.txt.
fn repo(tmp: &Path, name: &str) -> PathBuf {
    let d = tmp.join(name);
    std::fs::create_dir_all(&d).unwrap();
    sh(
        &d,
        "git init -q -b main && git config user.name t && git config user.email t@example.com \
         && git config commit.gpgsign false && printf 'one\\n' > a.txt && printf 'two\\n' > b.txt \
         && git add . && git commit -q -m init",
    );
    d
}

fn status_of(root: &Path) -> status::Status {
    read_repo(root, false, 0).0.unwrap()
}

fn paths(list: &[status::Change]) -> Vec<(String, char)> {
    list.iter().map(|c| (c.path.clone(), c.letter)).collect()
}

/// [D] The sections from porcelain v2: a staged rename, a staged file changed again (in both), a deletion, an
/// untracked file listed by name inside its folder, and a conflict in Merge Changes only.
#[test]
fn status_reads_sections_from_porcelain() {
    let out = [
        "# branch.oid 1234",
        "# branch.head main",
        "# branch.upstream origin/main",
        "# branch.ab +2 -1",
        "1 MM N... 100644 100644 100644 aaaa bbbb src/a b.rs",
        "1 .D N... 100644 100644 000000 aaaa aaaa gone.rs",
        "2 R. N... 100644 100644 100644 aaaa bbbb R100 renamed.rs",
        "old name.rs",
        "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc clash.rs",
        "? scratch/new.txt",
    ]
    .join("\0")
        + "\0";
    let st = status::parse(out.as_bytes());
    assert_eq!(st.head.name.as_deref(), Some("main"));
    assert_eq!(st.head.upstream.as_deref(), Some("origin/main"));
    assert_eq!((st.head.ahead, st.head.behind), (2, 1));
    assert_eq!(
        paths(&st.staged),
        [("renamed.rs".into(), 'R'), ("src/a b.rs".into(), 'M')]
    );
    assert_eq!(st.staged[0].orig.as_deref(), Some("old name.rs"));
    assert_eq!(
        paths(&st.changes),
        [
            ("gone.rs".into(), 'D'),
            ("scratch/new.txt".into(), 'U'),
            ("src/a b.rs".into(), 'M')
        ]
    );
    assert_eq!(paths(&st.merge), [("clash.rs".into(), 'C')]);
    assert_eq!(st.count(), 5);
}

/// A view of REPOS, all read.
fn view_of(repos: &[&Path]) -> ViewState {
    let mut v = ViewState {
        scanned: true,
        ..ViewState::default()
    };
    for r in repos {
        let mut s = RepoState::new(Found {
            root: r.to_path_buf(),
            name: r.file_name().unwrap().to_string_lossy().into_owned(),
            main: None,
        });
        s.status = Some(Ok(status_of(r)));
        v.repos.push(s);
    }
    v
}

fn tty() -> RowLook {
    RowLook {
        gui: None,
        one_root: true,
    }
}

fn keys(v: &ViewState) -> Vec<String> {
    let (rows, _) = rows::rows(v, &tty(), &rows::Room::wide(), 0);
    rows.into_iter().map(|r| r.key).collect()
}

fn text_of(v: &ViewState, key: &str) -> String {
    let (rows, _) = rows::rows(v, &tty(), &rows::Room::wide(), 0);
    rows.into_iter()
        .find(|r| r.key == key)
        .map(|r| r.text)
        .unwrap_or_default()
}

/// [D] One repository: no Repositories list; its header, branch, Commit button, then each section with its files,
/// then the graph (folded); `git add` in the repository moves the file from Changes to Staged Changes.
#[test]
fn rows_list_the_sections_and_follow_a_stage() {
    let tmp = tempfile::tempdir().unwrap();
    let r = repo(tmp.path(), "app");
    sh(&r, "printf 'more\\n' >> a.txt && printf 'n\\n' > new.txt");
    let root = r.to_string_lossy().into_owned();
    let v = view_of(&[&r]);
    let k = |parts: &[&str]| parts.join("\t");
    assert_eq!(
        keys(&v),
        [
            k(&["head", &root]),
            k(&["branch", &root]),
            k(&["commit", &root]),
            k(&["sec", &root, "changes"]),
            k(&["f", &root, "changes", "a.txt"]),
            k(&["f", &root, "changes", "new.txt"]),
            k(&["graph", &root]),
        ]
    );
    assert!(text_of(&v, &k(&["f", &root, "changes", "a.txt"])).contains("a.txt  M"));
    assert!(text_of(&v, &k(&["f", &root, "changes", "new.txt"])).contains("new.txt  U"));
    assert!(text_of(&v, &k(&["commit", &root])).contains("Commit on 'main'"));
    // stage a.txt as the view's git/stage does
    run::git(
        &r,
        As::User,
        &["add", "-A", "--", "a.txt"],
        None,
        Some(LOCAL),
        None,
    )
    .unwrap();
    let v = view_of(&[&r]);
    assert_eq!(
        keys(&v)[3..6],
        [
            k(&["sec", &root, "staged"]),
            k(&["f", &root, "staged", "a.txt"]),
            k(&["sec", &root, "changes"]),
        ]
    );
    // a folded section lists no files
    let mut v = v;
    v.toggled.insert(k(&["sec", &root, "staged"]));
    assert!(!keys(&v).contains(&k(&["f", &root, "staged", "a.txt"])));
}

/// The empty state wraps to the room it has, never cut: a narrow side bar gives it more rows, each within the room
/// (UX audit: at 1.25 it showed as "No changes. Your working tree m…").
#[test]
fn the_empty_state_wraps_to_its_room() {
    let tmp = tempfile::tempdir().unwrap();
    let r = repo(tmp.path(), "app");
    let root = r.to_string_lossy().into_owned();
    let v = view_of(&[&r]);
    // one px a char, room for 24
    let width = |_: Option<&str>, t: &str| t.chars().count() as f32;
    let room = rows::Room {
        width: &width,
        px: 24.0,
    };
    let (rs, _) = rows::rows(&v, &tty(), &room, 0);
    let notes: Vec<_> = rs.iter().filter(|r| r.key.starts_with(&format!("note\t{root}"))).collect();
    assert_eq!(notes[0].key, format!("note\t{root}"));
    assert!(notes.len() >= 2, "{notes:?}");
    for n in &notes {
        assert!(n.text.chars().count() <= 24, "{:?}", n.text);
        assert!(!n.text.contains('…'));
    }
    let words: Vec<String> = notes.iter().map(|n| n.text.trim().to_owned()).collect();
    assert_eq!(words.join(" "), rows::NO_CHANGES);
    // with room, one row as before
    let (rs, _) = rows::rows(&v, &tty(), &rows::Room::wide(), 0);
    assert_eq!(rs.iter().filter(|r| r.key.starts_with(&format!("note\t{root}"))).count(), 1);
}

/// [D] A clean repository shows the empty state; tree view groups files under folder rows, and a folded folder
/// hides what is in it.
#[test]
fn empty_state_and_tree_view() {
    let tmp = tempfile::tempdir().unwrap();
    let r = repo(tmp.path(), "app");
    let root = r.to_string_lossy().into_owned();
    let k = |parts: &[&str]| parts.join("\t");
    let v = view_of(&[&r]);
    assert!(text_of(&v, &k(&["note", &root])).contains(rows::NO_CHANGES));
    sh(
        &r,
        "mkdir -p src/deep && printf x > src/deep/x.rs && printf y > src/y.rs && printf z > z.txt",
    );
    let mut v = view_of(&[&r]);
    v.view_as = ViewAs::Tree;
    let ks = keys(&v);
    let at = ks
        .iter()
        .position(|x| *x == k(&["sec", &root, "changes"]))
        .unwrap();
    assert_eq!(
        ks[at + 1..at + 6],
        [
            k(&["d", &root, "changes", "src"]),
            k(&["d", &root, "changes", "src/deep"]),
            k(&["f", &root, "changes", "src/deep/x.rs"]),
            k(&["f", &root, "changes", "src/y.rs"]),
            k(&["f", &root, "changes", "z.txt"]),
        ]
    );
    v.toggled.insert(k(&["d", &root, "changes", "src"]));
    let ks = keys(&v);
    assert!(!ks.contains(&k(&["f", &root, "changes", "src/y.rs"])));
    assert!(!ks.contains(&k(&["d", &root, "changes", "src/deep"])));
    assert!(ks.contains(&k(&["f", &root, "changes", "z.txt"])));
}

/// [D] Discard: a tracked file's unstaged change goes back to the index's text and its staged change stays.
#[test]
fn discard_restores_the_index_text() {
    let tmp = tempfile::tempdir().unwrap();
    let r = repo(tmp.path(), "app");
    sh(
        &r,
        "printf 'staged\\n' > a.txt && git add a.txt && printf 'later\\n' > a.txt",
    );
    run::git(
        &r,
        As::User,
        &["restore", "--worktree", "--", "a.txt"],
        None,
        Some(LOCAL),
        None,
    )
    .unwrap();
    assert_eq!(
        std::fs::read_to_string(r.join("a.txt")).unwrap(),
        "staged\n"
    );
    let st = status_of(&r);
    assert_eq!(paths(&st.staged), [("a.txt".into(), 'M')]);
    assert!(st.changes.is_empty());
}

/// [D] A commit with nothing staged is git's refusal, its text the error; the message goes on stdin, and the
/// repository's own pre-commit hook runs (the user's commit, unlike draugr's reads, keeps the hooks).
#[test]
fn commit_takes_the_message_on_stdin_and_runs_the_hooks() {
    let tmp = tempfile::tempdir().unwrap();
    let r = repo(tmp.path(), "app");
    let none = run::git(
        &r,
        As::User,
        &["commit", "-q", "-F", "-"],
        Some(b"nothing"),
        Some(LOCAL),
        None,
    );
    assert!(none.is_err());
    sh(
        &r,
        "printf '#!/bin/sh\\necho ran > .git/hook-ran\\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit \
         && printf 'x\\n' >> a.txt && git add a.txt",
    );
    run::git(
        &r,
        As::User,
        &["commit", "-q", "-F", "-"],
        Some("subject\n\nbody".as_bytes()),
        Some(LOCAL),
        None,
    )
    .unwrap();
    assert!(r.join(".git/hook-ran").exists(), "the pre-commit hook ran");
    let log = run::git(
        &r,
        As::Reader,
        &["log", "-1", "--format=%B"],
        None,
        Some(LOCAL),
        None,
    )
    .unwrap();
    assert_eq!(String::from_utf8_lossy(&log).trim(), "subject\n\nbody");
}

/// [D] A git that outlives its deadline is stopped with its group and says so; a cancelled one says `stopped`.
#[test]
fn deadline_and_cancel_stop_a_hung_git() {
    let tmp = tempfile::tempdir().unwrap();
    let mut c = Command::new("/bin/sh");
    c.args(["-c", "sleep 30"]);
    let t = std::time::Instant::now();
    let e = run::run(c, tmp.path(), None, Some(Duration::from_millis(200)), None).unwrap_err();
    assert!(e.contains("longer than"), "{e}");
    assert!(t.elapsed() < Duration::from_secs(5));
    let cancel = Arc::new(AtomicBool::new(false));
    let c2 = cancel.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(100));
        c2.store(true, Ordering::Relaxed);
    });
    let mut c = Command::new("/bin/sh");
    c.args(["-c", "sleep 30"]);
    assert_eq!(
        run::run(c, tmp.path(), None, None, Some(&cancel)).unwrap_err(),
        run::STOPPED
    );
}

/// [D] Repositories: a workspace folder that is a repository, one nested in it, and a linked worktree, each once,
/// the worktree named after its main repository; never more than [`repos::REPOS_MAX`].
#[test]
fn repositories_nested_worktrees_and_the_cap() {
    let tmp = tempfile::tempdir().unwrap();
    let top = repo(tmp.path(), "org");
    let inner = repo(&top, "inner");
    sh(&inner, "git worktree add -q ../../wt-x -b x");
    let found = repos::find(std::slice::from_ref(&top));
    let names: Vec<&str> = found.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(names, ["org", "inner", "inner · wt-x"]);
    assert_eq!(found[2].main.as_deref(), Some(inner.as_path()));
    // the cap
    let many = tmp.path().join("many");
    for i in 0..(repos::REPOS_MAX + 5) {
        std::fs::create_dir_all(many.join(format!("r{i:03}/.git"))).unwrap();
    }
    assert_eq!(repos::find(&[many]).len(), repos::REPOS_MAX);
}

/// [D] Several repositories: the Repositories list first, then each selected one's block; one with no changes is
/// not shown until chosen.
#[test]
fn several_repositories_list_then_the_selected_blocks() {
    let tmp = tempfile::tempdir().unwrap();
    let a = repo(tmp.path(), "a");
    let b = repo(tmp.path(), "b");
    sh(&a, "printf x >> a.txt");
    let (ra, rb) = (
        a.to_string_lossy().into_owned(),
        b.to_string_lossy().into_owned(),
    );
    let mut v = view_of(&[&a, &b]);
    let ks = keys(&v);
    assert_eq!(
        ks[..3],
        [
            "repos".to_owned(),
            format!("repo\t{ra}"),
            format!("repo\t{rb}")
        ]
    );
    assert!(text_of(&v, &format!("repo\t{ra}")).contains("[x] a  main  1"));
    assert!(text_of(&v, &format!("repo\t{rb}")).contains("[ ] b  main"));
    assert!(ks.contains(&format!("head\t{ra}")));
    assert!(!ks.contains(&format!("head\t{rb}")));
    v.chosen.insert(b.clone(), true);
    assert!(keys(&v).contains(&format!("head\t{rb}")));
}

/// [D] Against a bare origin: ahead and behind counts, then the graph's lanes for a merge and its incoming and
/// outgoing commits.
#[test]
fn remote_counts_and_graph_lanes() {
    let tmp = tempfile::tempdir().unwrap();
    let r = repo(tmp.path(), "app");
    sh(
        tmp.path(),
        "git init -q --bare -b main origin.git &&cd app && git remote add origin ../origin.git \
         && git push -q -u origin main && git clone -q ../origin.git ../other \
         && cd ../other && git config user.name o && git config user.email o@example.com \
         && printf 'theirs\\n' > c.txt && git add c.txt && git commit -q -m theirs && git push -q",
    );
    sh(
        &r,
        "git checkout -q -b side && printf s > s.txt && git add s.txt && git commit -q -m side \
         && git checkout -q main && printf m > m.txt && git add m.txt && git commit -q -m main-work \
         && git merge -q --no-ff -m merge side && git fetch -q",
    );
    let st = status_of(&r);
    assert_eq!((st.head.ahead, st.head.behind), (3, 1));
    let g = read_graph(&r, &st, graph::PAGE);
    let subjects: Vec<&str> = g.commits.iter().map(|c| c.subject.as_str()).collect();
    assert_eq!(subjects[0], "merge");
    assert!(subjects.contains(&"theirs") && subjects.contains(&"init"));
    let at = |s: &str| g.commits.iter().position(|c| c.subject == s).unwrap();
    assert!(g.lanes[at("merge")].starts_with('●') && g.lanes[at("merge")].contains('╮'));
    assert!(g.incoming.contains(&g.commits[at("theirs")].sha));
    assert!(g.outgoing.contains(&g.commits[at("side")].sha));
    assert!(g.outgoing.contains(&g.commits[at("merge")].sha));
    assert!(!g.outgoing.contains(&g.commits[at("init")].sha));
}

/// [D] The lanes of a merge drawn by hand: the merge opens a lane for its second parent, which ends in their base.
#[test]
fn lanes_of_a_merge() {
    let c = |sha: &str, parents: &[&str]| graph::Commit {
        sha: sha.into(),
        parents: parents.iter().map(|p| (*p).into()).collect(),
        author: String::new(),
        time: 0,
        refs: vec![],
        subject: String::new(),
    };
    let commits = [
        c("m", &["a", "b"]),
        c("a", &["base"]),
        c("b", &["base"]),
        c("base", &[]),
    ];
    assert_eq!(graph::lanes(&commits), ["●╮", "●│", "│●", "●╯"]);
}

/// [D] The branch picker's list: local branches first (the current one marked), then remote ones without
/// `origin/HEAD`.
#[test]
fn branches_local_then_remote() {
    let out = "refs/heads/main\x001700\x00*\nrefs/remotes/origin/HEAD\x001700\x00 \n\
               refs/remotes/origin/main\x001600\x00 \nrefs/heads/dev\x001500\x00 \n";
    let b = parse_branches(out.as_bytes());
    let names: Vec<(&str, bool, bool)> = b
        .iter()
        .map(|b| (b.name.as_str(), b.remote, b.current))
        .collect();
    assert_eq!(
        names,
        [
            ("main", false, true),
            ("dev", false, false),
            ("origin/main", true, false)
        ]
    );
}

/// [D] Ages as the graph writes them.
#[test]
fn ages() {
    assert_eq!(graph::age(100, 110), "now");
    assert_eq!(graph::age(0, 3 * 3600), "3h");
    assert_eq!(graph::age(0, 2 * 86_400), "2d");
    assert_eq!(graph::age(0, 400 * 86_400), "1y");
}

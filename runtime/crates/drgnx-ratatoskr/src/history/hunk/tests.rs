//! A paired chat's hunk on the user's branch: listed by its session, reverted with the user's typing kept, by the hub
//! when no buffer holds the file and by the editor's batch when one does.
//! Pattern D (a temporary repository and `history.db`, no clock; every time is a parameter).

use super::super::methods::hash;
use super::super::{BatchChange, BatchReply, Hub, Tree};
use super::Outcome;
use norn::deny::DenyList;
use std::path::Path;
use verdandi::{HunkState, Kind, OpId};

fn git(dir: &Path, args: &[&str]) {
    let ok = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .status()
        .unwrap()
        .success();
    assert!(ok, "git {args:?}");
}

struct Fx {
    _home: tempfile::TempDir,
    _hist: tempfile::TempDir,
    hub: Hub,
    tree: Tree,
}

/// A project with a.txt committed, tracked as buffer `b1`; the chat `s9` wrote a line into it and the user typed inside
/// that line; both settled into records.  The chat's record.
fn fx() -> (Fx, OpId) {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join("proj");
    std::fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    std::fs::write(root.join("a.txt"), "one\ntwo\n").unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-q", "-m", "base"]);
    let head = String::from_utf8(
        std::process::Command::new("git")
            .args(["rev-parse", "HEAD"])
            .current_dir(&root)
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap()
    .trim()
    .to_owned();
    let cfg = home.path().join("config");
    std::fs::create_dir_all(&cfg).unwrap();
    let deny = DenyList::load(home.path(), &cfg);
    let hist = tempfile::tempdir().unwrap();
    let hub = Hub::open(hist.path()).unwrap();
    let tree = Tree::new(&root, &root.join(".git"), Some(&head));
    assert!(hub.register(&tree, "a.txt", "b1", &deny).unwrap().tracked);
    let ch = |start, inserted: &str, origin: &str| BatchChange {
        start,
        old_len: 0,
        inserted: inserted.into(),
        origin: origin.into(),
    };
    let ok = |r| assert_eq!(r, BatchReply::Ok);
    ok(hub
        .batch(
            "b1",
            &[ch(4, "alpha beta\n", "agent:s9")],
            &hash("one\nalpha beta\ntwo\n"),
            5.0,
        )
        .unwrap());
    ok(hub
        .batch(
            "b1",
            &[ch(9, "ZZ", "user")],
            &hash("one\nalphaZZ beta\ntwo\n"),
            6.0,
        )
        .unwrap());
    assert_eq!(hub.settle_due(100.0).unwrap(), 2);
    let listed = hub.op_hunks(&tree, None, Some("s9"), 100.0).unwrap();
    assert_eq!(listed.len(), 1, "{listed:?}");
    let (h, by) = &listed[0];
    assert_eq!(
        (h.index, h.start_line, h.text.as_str(), h.state),
        (0, 2, "alpha beta\n", HunkState::Live)
    );
    assert!(by.is_empty());
    let op = h.op;
    (
        Fx {
            _home: home,
            _hist: hist,
            hub,
            tree,
        },
        op,
    )
}

const KEPT: &str = "one\nZZtwo\n";

#[test]
fn a_chats_hunk_with_no_buffer_is_reverted_and_written_by_the_hub() {
    let (f, op) = fx();
    // the editor saved and closed the file
    f.hub.unregister("b1");
    std::fs::write(f.tree.root.join("a.txt"), "one\nalphaZZ beta\ntwo\n").unwrap();
    let rev = match f.hub.revert_hunk(&f.tree, op.0, "a.txt", 0, 200.0).unwrap() {
        Outcome::Applied(r) => r,
        other => panic!("{other:?}"),
    };
    assert_eq!(
        std::fs::read_to_string(f.tree.root.join("a.txt")).unwrap(),
        KEPT
    );
    assert_eq!(f.hub.text(&f.tree, "a.txt").unwrap().as_deref(), Some(KEPT));
    let r = f.hub.with(|h| h.op(rev).unwrap());
    assert_eq!((r.kind, r.parents), (Kind::Revert, vec![op]));
}

#[test]
fn a_chats_hunk_in_a_buffer_is_applied_by_the_editors_batch() {
    let (f, op) = fx();
    let (version, edits) = match f.hub.revert_hunk(&f.tree, op.0, "a.txt", 0, 200.0).unwrap() {
        Outcome::InBuffer {
            buffer_id,
            version,
            edits,
        } => {
            assert_eq!(buffer_id, "b1");
            (version, edits)
        }
        other => panic!("{other:?}"),
    };
    assert_eq!(version, hash("one\nalphaZZ beta\ntwo\n"));
    // the hub wrote nothing: neither the file nor the document
    assert_eq!(
        std::fs::read_to_string(f.tree.root.join("a.txt")).unwrap(),
        "one\ntwo\n"
    );
    assert_eq!(
        f.hub.text(&f.tree, "a.txt").unwrap().as_deref(),
        Some("one\nalphaZZ beta\ntwo\n")
    );
    // the editor applies the edits as the revert's origin; its drain sends them back
    let origin = format!("revert:{}", op.0);
    let changes: Vec<BatchChange> = edits
        .iter()
        .map(|c| BatchChange {
            start: c.start,
            old_len: c.old_len,
            inserted: c.inserted.clone(),
            origin: origin.clone(),
        })
        .collect();
    assert_eq!(
        f.hub.batch("b1", &changes, &hash(KEPT), 201.0).unwrap(),
        BatchReply::Ok
    );
    assert_eq!(f.hub.text(&f.tree, "a.txt").unwrap().as_deref(), Some(KEPT));
    let listed = f.hub.op_hunks(&f.tree, Some(op.0), None, 202.0).unwrap();
    let (h, by) = &listed[0];
    assert_eq!(h.state, HunkState::Undone);
    assert_eq!(by.len(), 1, "{by:?}");
    let (rev, author) = &by[0];
    assert_eq!(author.as_ref().unwrap()["kind"], "user", "undone by you");
    let r = f.hub.with(|h| h.op(*rev).unwrap());
    assert_eq!((r.kind, r.parents), (Kind::Revert, vec![op]));
}

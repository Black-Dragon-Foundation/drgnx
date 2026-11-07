//! Capture of agent, external and git changes onto a real `history.db`, in a real git repository (pattern D: a
//! temporary folder, git, no process of the hub, every time a parameter).

use super::super::{Class, Hub, Tree};
use std::path::Path;
use verdandi::{Cause, Kind, OpId};

fn git(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
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
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {out:?}");
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

struct Fixture {
    repo: tempfile::TempDir,
    hist: tempfile::TempDir,
    hub: Hub,
    tree: Tree,
}

/// A repository with FILES committed, a hub on a fresh `history.db`, and the repository's tree (base: the commit).
fn fixture(files: &[(&str, &str)]) -> Fixture {
    let repo = tempfile::tempdir().unwrap();
    git(repo.path(), &["init", "-q", "-b", "main"]);
    for (p, t) in files {
        let f = repo.path().join(p);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(f, t).unwrap();
    }
    git(repo.path(), &["add", "."]);
    git(repo.path(), &["commit", "-q", "-m", "base"]);
    let head = git(repo.path(), &["rev-parse", "HEAD"]);
    let hist = tempfile::tempdir().unwrap();
    let hub = Hub::open(hist.path()).unwrap();
    let tree = Tree::new(repo.path(), &repo.path().join(".git"), Some(&head));
    Fixture {
        repo,
        hist,
        hub,
        tree,
    }
}

fn author(f: &Fixture, op: i64) -> serde_json::Value {
    f.hub.with(|h| {
        let r = h.op(OpId(op)).unwrap();
        h.author_of(r.author).unwrap().unwrap()
    })
}

fn kind(f: &Fixture, op: i64) -> Kind {
    f.hub.with(|h| h.op(OpId(op)).unwrap().kind)
}

fn cause(step: &str) -> Cause {
    Cause {
        session: Some("s1".into()),
        step: Some(step.into()),
        ..Cause::default()
    }
}

#[test]
fn agent_write_becomes_ops_on_its_branch_with_cause() {
    let f = fixture(&[("a.txt", "one\ntwo\n")]);
    let v = f
        .hub
        .on_agent_write(
            &f.tree,
            "a.txt",
            b"one\nTWO\nthree\n",
            "s1",
            cause("7"),
            10.0,
        )
        .unwrap();
    assert_eq!(v.len(), 1);
    assert_eq!(v[0].class, Class::Text);
    assert_eq!(
        f.hub.text(&f.tree, "a.txt").unwrap().as_deref(),
        Some("one\nTWO\nthree\n")
    );
    assert_eq!(kind(&f, v[0].op), Kind::AgentStep);
    let rec = f.hub.with(|h| h.op(OpId(v[0].op)).unwrap());
    assert_eq!(rec.cause.step.as_deref(), Some("7"));
    assert_eq!(author(&f, v[0].op)["session"], "s1");
    assert!(!rec.spans.is_empty());
}

/// A made-up key of a well-known shape.
fn key() -> String {
    format!("sk-{}", "q".repeat(30))
}

#[test]
fn a_key_in_an_agent_write_is_stored_as_stars_and_not_again() {
    let f = fixture(&[("a.txt", "one\n")]);
    let body = format!("one\nTOKEN={}\n", key());
    let v = f
        .hub
        .on_agent_write(&f.tree, "a.txt", body.as_bytes(), "s1", cause("1"), 10.0)
        .unwrap();
    assert_eq!(v.len(), 1);
    let stored = f.hub.text(&f.tree, "a.txt").unwrap().unwrap();
    assert_eq!(stored, format!("one\nTOKEN={}\n", "*".repeat(33)));
    // the file on disk still has the key: the next look at it is no new version
    let again = f
        .hub
        .on_agent_write(&f.tree, "a.txt", body.as_bytes(), "s1", cause("2"), 11.0)
        .unwrap();
    assert!(again.is_empty(), "{again:?}");
}

/// What a consumer of the `history/file-version` event (the indexer, the Work space) reads: the frozen JSON shape of a
/// version, as the subscription delivers it.
#[test]
fn a_consumer_of_file_version_reads_the_frozen_shape() {
    let f = fixture(&[("a.txt", "one\n")]);
    let mut rx = f.hub.subscribe();
    let v = f
        .hub
        .on_agent_write(&f.tree, "a.txt", b"one\ntwo\n", "s1", cause("1"), 10.0)
        .unwrap();
    let got = serde_json::to_value(rx.try_recv().unwrap()).unwrap();
    let blob = got["blob"].as_str().unwrap().to_owned();
    assert_eq!(blob.len(), 40, "a git blob id: {got}");
    assert!(blob.bytes().all(|b| b.is_ascii_hexdigit()), "{got}");
    assert_eq!(
        got,
        serde_json::json!({
            "worktree": f.tree.id.0,
            "path": "a.txt",
            "blob": blob,
            "op": v[0].op,
            "class": "text",
        })
    );
    // a file that is gone says so: a null blob
    std::fs::remove_file(f.repo.path().join("a.txt")).unwrap();
    f.hub.on_disk_change(&f.tree, "a.txt", 11.0).unwrap();
    let gone = serde_json::to_value(rx.try_recv().unwrap()).unwrap();
    assert!(gone["blob"].is_null(), "{gone}");
}

#[test]
fn external_change_is_diffed_onto_disk_peer() {
    let f = fixture(&[("a.txt", "one\ntwo\n")]);
    std::fs::write(f.repo.path().join("a.txt"), "one\ntwo\nthree\n").unwrap();
    let v = f.hub.on_disk_change(&f.tree, "a.txt", 11.0).unwrap();
    assert_eq!(v.len(), 1);
    assert_eq!(
        f.hub.text(&f.tree, "a.txt").unwrap().as_deref(),
        Some("one\ntwo\nthree\n")
    );
    assert_eq!(kind(&f, v[0].op), Kind::External);
    assert_eq!(author(&f, v[0].op)["source"], "disk");
}

#[test]
fn git_checkout_is_one_external_git_record() {
    let f = fixture(&[("a.txt", "a1\n"), ("b.txt", "b1\n")]);
    let old = git(f.repo.path(), &["rev-parse", "HEAD"]);
    std::fs::write(f.repo.path().join("a.txt"), "a2\n").unwrap();
    std::fs::write(f.repo.path().join("b.txt"), "b2\n").unwrap();
    git(f.repo.path(), &["commit", "-q", "-am", "next"]);
    let new = git(f.repo.path(), &["rev-parse", "HEAD"]);
    let v = f
        .hub
        .on_git_event(&f.tree, &old, &new, "checkout", 12.0)
        .unwrap();
    assert_eq!(v.len(), 2, "{v:?}");
    assert_eq!(v[0].op, v[1].op, "one record for the whole checkout");
    assert_eq!(kind(&f, v[0].op), Kind::External);
    assert_eq!(author(&f, v[0].op)["source"], "git");
    assert_eq!(
        f.hub.text(&f.tree, "b.txt").unwrap().as_deref(),
        Some("b2\n")
    );
    assert_eq!(f.hub.with(|h| h.op(OpId(v[0].op)).unwrap().spans.len()), 2);
}

/// Pattern D. What a tree held against its head when the watcher started (an uncommitted line, a new file) is recorded
/// once: a second start finds it known, and a file equal to the head's is no version.
#[test]
fn a_trees_uncommitted_state_is_rescanned_once() {
    let f = fixture(&[("a.txt", "one\n"), ("same.txt", "x\n")]);
    std::fs::write(f.repo.path().join("a.txt"), "one\nfrom-b\n").unwrap();
    std::fs::write(f.repo.path().join("new.txt"), "n\n").unwrap();
    let mut got: Vec<String> = f
        .hub
        .rescan_dirty(&f.tree, 10.0)
        .unwrap()
        .into_iter()
        .map(|v| v.path)
        .collect();
    got.sort();
    assert_eq!(got, ["a.txt", "new.txt"]);
    assert!(f.hub.rescan_dirty(&f.tree, 11.0).unwrap().is_empty());
    assert_eq!(f.hub.with(|h| h.count("op").unwrap()), 1);
}

#[test]
fn drgnx_write_is_not_recorded_twice() {
    let f = fixture(&[("a.txt", "one\n")]);
    let bytes = b"one\ntwo\n";
    f.hub
        .on_agent_write(&f.tree, "a.txt", bytes, "s1", cause("1"), 10.0)
        .unwrap();
    std::fs::write(f.repo.path().join("a.txt"), bytes).unwrap();
    // the watcher's event and a step-boundary rescan about the hub's own write
    assert!(
        f.hub
            .on_disk_change(&f.tree, "a.txt", 11.0)
            .unwrap()
            .is_empty()
    );
    assert!(
        f.hub
            .rescan(&f.tree, &["a.txt".to_owned()], 12.0)
            .unwrap()
            .is_empty()
    );
    assert_eq!(f.hub.with(|h| h.count("op").unwrap()), 1);
}

/// The same path with the same bytes in two trees of one project is two files: each tree's write is its own version, and
/// the watcher's event about one tree's file is not the other's.
#[test]
fn the_same_path_in_two_trees_is_two_versions() {
    let f = fixture(&[("a.txt", "one\n")]);
    let other = fixture(&[("a.txt", "one\n")]);
    let bytes = b"one\ntwo\n";
    let first = f
        .hub
        .on_agent_write(&f.tree, "a.txt", bytes, "s1", cause("1"), 10.0)
        .unwrap();
    let second = f
        .hub
        .on_agent_write(&other.tree, "a.txt", bytes, "s2", cause("1"), 11.0)
        .unwrap();
    assert_eq!(first.len(), 1);
    assert_eq!(
        second.len(),
        1,
        "the second tree's write is its own version"
    );
    assert_eq!(
        f.hub.text(&other.tree, "a.txt").unwrap().as_deref(),
        Some("one\ntwo\n")
    );
    // an outside change in the second tree after the first tree's write is not mistaken for the first tree's version
    std::fs::write(other.repo.path().join("a.txt"), "one\ntwo\nthree\n").unwrap();
    let outside = f.hub.on_disk_change(&other.tree, "a.txt", 12.0).unwrap();
    assert_eq!(outside.len(), 1);
    assert_eq!(kind(&f, outside[0].op), Kind::External);
}

#[test]
fn crlf_file_blob_id_matches_git() {
    let f = fixture(&[("a.txt", "x\n")]);
    git(f.repo.path(), &["config", "core.autocrlf", "true"]);
    std::fs::write(f.repo.path().join("a.txt"), "one\r\ntwo\r\n").unwrap();
    let v = f.hub.on_disk_change(&f.tree, "a.txt", 11.0).unwrap();
    let want = git(f.repo.path(), &["hash-object", "--path", "a.txt", "a.txt"]);
    let raw = git(f.repo.path(), &["hash-object", "--no-filters", "a.txt"]);
    assert_ne!(want, raw, "the filter changed the bytes");
    assert_eq!(v[0].blob.as_deref(), Some(want.as_str()));
    // the document holds LF
    assert_eq!(
        f.hub.text(&f.tree, "a.txt").unwrap().as_deref(),
        Some("one\ntwo\n")
    );
}

#[test]
fn lockfile_goes_to_snapshot_class() {
    let f = fixture(&[("Cargo.lock", "v1\n")]);
    std::fs::write(f.repo.path().join("Cargo.lock"), "v2\n").unwrap();
    let v = f.hub.on_disk_change(&f.tree, "Cargo.lock", 11.0).unwrap();
    assert_eq!(v.len(), 1);
    assert_eq!(v[0].class, Class::Snapshot);
    assert!(v[0].blob.is_some());
    assert_eq!(f.hub.with(|h| h.count("doc").unwrap()), 0);
}

#[test]
fn agent_mv_is_a_rename_record() {
    let f = fixture(&[("a.txt", "one\ntwo\n")]);
    std::fs::rename(f.repo.path().join("a.txt"), f.repo.path().join("b.txt")).unwrap();
    let v = f
        .hub
        .on_agent_rename(&f.tree, "a.txt", "b.txt", "s1", cause("2"), 10.0)
        .unwrap();
    assert!(!v.is_empty());
    assert_eq!(kind(&f, v[0].op), Kind::Rename);
    assert_eq!(
        f.hub.text(&f.tree, "b.txt").unwrap().as_deref(),
        Some("one\ntwo\n")
    );
    assert_eq!(f.hub.text(&f.tree, "a.txt").unwrap().as_deref(), Some(""));
}

/// A link planted where a file was: it is recorded as a link (its target's name), never read through.
fn plant_link(f: &Fixture) -> std::path::PathBuf {
    let outside = tempfile::tempdir().unwrap();
    let secret = outside.path().join("secret.txt");
    std::fs::write(&secret, "TOPSECRET\n").unwrap();
    std::fs::remove_file(f.repo.path().join("src/a.rs")).unwrap();
    std::os::unix::fs::symlink(&secret, f.repo.path().join("src/a.rs")).unwrap();
    std::mem::forget(outside);
    secret
}

#[test]
fn link_is_recorded_as_a_link() {
    let f = fixture(&[("src/a.rs", "fn a() {}\n")]);
    let secret = plant_link(&f);
    let v = f.hub.on_disk_change(&f.tree, "src/a.rs", 11.0).unwrap();
    assert_eq!(v.len(), 1);
    assert_eq!(v[0].class, Class::Snapshot);
    // git stores a link as a blob of its target's name
    let target = f.hist.path().join("target");
    std::fs::write(&target, secret.to_string_lossy().as_bytes()).unwrap();
    let want = git(
        f.repo.path(),
        &["hash-object", "--no-filters", target.to_str().unwrap()],
    );
    assert_eq!(v[0].blob.as_deref(), Some(want.as_str()));
}

// [D] pure: a hub write the after-edit hook changed is recorded as the bytes that reach the disk, not the agent's own
#[test]
fn records_the_bytes_after_the_hook() {
    let f = fixture(&[("a.txt", "one\n")]);
    let asked = b"one\ntwo\n";
    let written = b"one\ntwo\n// checked\n";
    let v = f
        .hub
        .on_agent_write(&f.tree, "a.txt", written, "s1", cause("2"), 10.0)
        .unwrap();
    assert_eq!(v.len(), 1);
    let git_dir = f.repo.path().join(".git");
    let blob = |bytes: &[u8]| {
        super::super::blob::hash_object(&git_dir, f.repo.path(), "a.txt", bytes).unwrap()
    };
    assert_eq!(v[0].blob.as_deref(), Some(blob(written).as_str()));
    assert_ne!(v[0].blob.as_deref(), Some(blob(asked).as_str()));
    assert_eq!(
        f.hub.text(&f.tree, "a.txt").unwrap().as_deref(),
        Some("one\ntwo\n// checked\n")
    );
}

#[test]
fn reads_through_eitri_only() {
    let f = fixture(&[("src/a.rs", "fn a() {}\n")]);
    plant_link(&f);
    f.hub.on_disk_change(&f.tree, "src/a.rs", 11.0).unwrap();
    f.hub.close().unwrap();
    for name in ["history.db", "history.db-wal"] {
        if let Ok(bytes) = std::fs::read(f.hist.path().join(name)) {
            assert!(
                !bytes.windows(9).any(|w| w == b"TOPSECRET"),
                "{name} holds the file the link points at"
            );
        }
    }
}

/// While an agent session works in a tree, the watcher's event about a file waits for the step that wrote it: the
/// step's rescan claims it as the agent's (session and step), and an event no step claims is recorded as an outside
/// change once it has waited [`super::HOLD`].
#[test]
fn a_watcher_event_waits_for_the_step_that_claims_it() {
    let Fixture {
        repo,
        hist: _hist,
        hub,
        tree,
    } = fixture(&[("a.txt", "one\n"), ("b.txt", "one\n")]);
    let hub = std::sync::Arc::new(hub);
    let attached = hub.attach_agent(&tree);
    // the agent's tool wrote a.txt in its process; the user's other editor wrote b.txt
    std::fs::write(repo.path().join("a.txt"), "one\ntwo\n").unwrap();
    std::fs::write(repo.path().join("b.txt"), "one\nmine\n").unwrap();
    assert!(hub.on_disk_change(&tree, "a.txt", 10.0).unwrap().is_empty());
    assert!(hub.on_disk_change(&tree, "b.txt", 10.0).unwrap().is_empty());
    assert!(
        hub.release_held(&tree, 11.0).unwrap().is_empty(),
        "within the hold"
    );
    let v = hub
        .rescan_by(&tree, &["a.txt".into()], "s1", cause("4"), 11.5)
        .unwrap();
    assert_eq!(v.len(), 1);
    assert_eq!(kind_of(&hub, v[0].op), Kind::AgentStep);
    assert_eq!(hub.with(|h| h.op(OpId(v[0].op)).unwrap().cause), cause("4"));
    let out = hub.release_held(&tree, 10.0 + super::HOLD).unwrap();
    assert_eq!(out.len(), 1, "b.txt only: a.txt was claimed");
    assert_eq!(out[0].path, "b.txt");
    assert_eq!(kind_of(&hub, out[0].op), Kind::External);
    // no agent session: an event is recorded at once
    drop(attached);
    std::fs::write(repo.path().join("b.txt"), "one\n").unwrap();
    assert_eq!(hub.on_disk_change(&tree, "b.txt", 20.0).unwrap().len(), 1);
}

fn kind_of(hub: &Hub, op: i64) -> Kind {
    hub.with(|h| h.op(OpId(op)).unwrap().kind)
}

//! Hrafn's watcher events into the hub: one watcher per project, a second reader of its stream (`Project::tap`), never
//! a second `notify` watcher.  A changed file is diffed onto its document (the origin core drops the hub's own writes);
//! a change to `HEAD`, the index or a ref rescans every path the hub knows.

use super::{FileVersion, Hub, Tree, blob};
use hrafn::WatchEvent;
use std::sync::mpsc::Receiver;

/// What EV did to the history of TREE, which the watcher knows by KEY: only that tree's events count, and their
/// paths are relative to TREE's root. An overflow lost events of every tree, so it rescans.
pub fn feed(hub: &Hub, tree: &Tree, key: &str, ev: &WatchEvent, now: f64) -> Vec<FileVersion> {
    let done = match ev {
        WatchEvent::File { tree: t, rel }
            if t == key && !blob::is_ignored(&tree.git_dir, &tree.root, rel) =>
        {
            hub.on_disk_change(tree, rel, now)
        }
        WatchEvent::Git { tree: t } if t == key => hub.rescan_known(tree, now),
        WatchEvent::Overflow => hub.rescan_known(tree, now),
        _ => return Vec::new(),
    };
    done.unwrap_or_else(|e| {
        tracing::warn!("history: a watcher event was not recorded: {e}");
        Vec::new()
    })
}

/// Everything RX holds now, fed in order.
pub fn pump(
    hub: &Hub,
    tree: &Tree,
    key: &str,
    rx: &Receiver<WatchEvent>,
    now: f64,
) -> Vec<FileVersion> {
    rx.try_iter()
        .flat_map(|e| feed(hub, tree, key, &e, now))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // pattern: D
    #[test]
    fn a_watcher_event_is_diffed_onto_the_document() {
        let repo = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            assert!(
                std::process::Command::new("git")
                    .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                    .args(args)
                    .current_dir(repo.path())
                    .env("GIT_CONFIG_GLOBAL", "/dev/null")
                    .status()
                    .unwrap()
                    .success()
            )
        };
        run(&["init", "-q", "-b", "main"]);
        std::fs::write(repo.path().join("a.txt"), "one\n").unwrap();
        run(&["add", "."]);
        run(&["commit", "-q", "-m", "base"]);
        let hist = tempfile::tempdir().unwrap();
        let hub = Hub::open(hist.path()).unwrap();
        let tree = Tree::new(repo.path(), &repo.path().join(".git"), None);
        std::fs::write(repo.path().join("a.txt"), "one\ntwo\n").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let file = |t: &str| WatchEvent::File {
            tree: t.into(),
            rel: "a.txt".into(),
        };
        tx.send(file("t")).unwrap();
        tx.send(WatchEvent::Lock {
            tree: "t".into(),
            held: true,
        })
        .unwrap();
        // the same content again (a second event for one save) is no new version
        tx.send(file("t")).unwrap();
        let v = pump(&hub, &tree, "t", &rx, 1.0);
        assert_eq!(v.len(), 1, "{v:?}");
        assert_eq!(
            hub.text(&tree, "a.txt").unwrap().as_deref(),
            Some("one\ntwo\n")
        );
    }

    // pattern: D
    #[test]
    fn history_pump_gets_tree_relative_paths() {
        let repo = tempfile::tempdir().unwrap();
        let run = |dir: &std::path::Path, args: &[&str]| {
            assert!(
                std::process::Command::new("git")
                    .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                    .args(args)
                    .current_dir(dir)
                    .env("GIT_CONFIG_GLOBAL", "/dev/null")
                    .status()
                    .unwrap()
                    .success()
            )
        };
        run(repo.path(), &["init", "-q", "-b", "main"]);
        std::fs::write(repo.path().join("a.txt"), "one\n").unwrap();
        run(repo.path(), &["add", "."]);
        run(repo.path(), &["commit", "-q", "-m", "base"]);
        // a linked worktree, nested in the main checkout like the agents' ones
        let wt = repo.path().join("wt/x");
        run(
            repo.path(),
            &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "x"],
        );
        let git_dir = repo.path().join(".git/worktrees/x");
        let hist = tempfile::tempdir().unwrap();
        let hub = Hub::open(hist.path()).unwrap();
        let tree = Tree::new(&wt, &git_dir, None);
        std::fs::write(wt.join("a.txt"), "one\ntwo\n").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        // the watcher's events for the worktree carry its own key and a path relative to it; another tree's are not ours
        tx.send(WatchEvent::File {
            tree: "x".into(),
            rel: "a.txt".into(),
        })
        .unwrap();
        std::fs::write(wt.join("b.txt"), "other\n").unwrap();
        tx.send(WatchEvent::File {
            tree: "other".into(),
            rel: "b.txt".into(),
        })
        .unwrap();
        let v = pump(&hub, &tree, "x", &rx, 1.0);
        assert_eq!(v.len(), 1, "{v:?}");
        assert_eq!(v[0].path, "a.txt");
        assert_eq!(
            hub.text(&tree, "a.txt").unwrap().as_deref(),
            Some("one\ntwo\n")
        );
    }
}

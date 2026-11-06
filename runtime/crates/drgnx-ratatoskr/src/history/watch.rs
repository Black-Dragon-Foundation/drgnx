//! Hrafn's watcher events into the hub: one watcher per project, a second reader of its stream (`Project::tap`), never
//! a second `notify` watcher.  A changed file is diffed onto its document (the origin core drops the hub's own writes);
//! a change to `HEAD`, the index or a ref rescans every path the hub knows.

use super::{FileVersion, Hub, Tree, blob};
use hrafn::WatchEvent;
use std::sync::mpsc::Receiver;

/// What EV did to the history of TREE.
pub fn feed(hub: &Hub, tree: &Tree, ev: &WatchEvent, now: f64) -> Vec<FileVersion> {
    let done = match ev {
        WatchEvent::File(rel) if !blob::is_ignored(&tree.git_dir, &tree.root, rel) => {
            hub.on_disk_change(tree, rel, now)
        }
        WatchEvent::Git => hub.rescan_known(tree, now),
        _ => return Vec::new(),
    };
    done.unwrap_or_else(|e| {
        tracing::warn!("history: a watcher event was not recorded: {e}");
        Vec::new()
    })
}

/// Everything RX holds now, fed in order.
pub fn pump(hub: &Hub, tree: &Tree, rx: &Receiver<WatchEvent>, now: f64) -> Vec<FileVersion> {
    rx.try_iter()
        .flat_map(|e| feed(hub, tree, &e, now))
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
        tx.send(WatchEvent::File("a.txt".into())).unwrap();
        tx.send(WatchEvent::Lock(true)).unwrap();
        // the same content again (a second event for one save) is no new version
        tx.send(WatchEvent::File("a.txt".into())).unwrap();
        let v = pump(&hub, &tree, &rx, 1.0);
        assert_eq!(v.len(), 1, "{v:?}");
        assert_eq!(
            hub.text(&tree, "a.txt").unwrap().as_deref(),
            Some("one\ntwo\n")
        );
    }
}

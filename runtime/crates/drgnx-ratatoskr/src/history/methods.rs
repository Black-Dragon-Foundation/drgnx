//! The hub's side of the editor's tracking: `register` a buffer's file, `batch` its changes, `resync` its text,
//! `unregister` it.  A batch's changes are character offsets in the document's LF text, applied as the batch's origin's
//! peer: the user's, or `agent:<session>` for a change merged in from an agent.

use super::capture::{diff, is_secret};
use super::{Buffer, Hub, Tree, blob};
use norn::deny::{DenyList, Verdict};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use verdandi::{BranchKind, Change, Error, Result};

/// A batch with more inserted bytes than this is refused with `split-required`: the editor splits it.
pub const BATCH_MAX: usize = 1 << 20;

/// One change of a batch: OLD_LEN characters at START replaced by INSERTED, made by ORIGIN (`user`, `agent:<session>`).
#[derive(Clone, Debug, PartialEq)]
pub struct BatchChange {
    pub start: usize,
    pub old_len: usize,
    pub inserted: String,
    pub origin: String,
}

/// What `register` answers.
#[derive(Clone, Debug, PartialEq)]
pub struct Registered {
    pub doc: i64,
    pub tracked: bool,
    /// Why the file is not tracked: `personal`, `secret` or `ignored`.
    pub reason: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BatchReply {
    Ok,
    /// The buffer and the document disagree: send the whole text (`resync`).
    Resync,
}

/// The hash a batch carries: SHA-256, in hex, of the buffer's whole text after the batch.
pub fn hash(text: &str) -> String {
    Sha256::digest(text.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn author_of(origin: &str) -> (String, Value) {
    match origin.strip_prefix("agent:") {
        Some(s) => (origin.to_owned(), json!({"kind": "agent", "session": s})),
        None if origin == "user" => ("user".to_owned(), json!({"kind": "user"})),
        None => (
            format!("origin:{origin}"),
            json!({"kind": "origin", "name": origin}),
        ),
    }
}

impl Hub {
    /// Track REL of TREE for BUFFER_ID, unless it is a personal file (DENY), a credentials file or ignored by git.
    pub fn register(
        &self,
        tree: &Tree,
        rel: &str,
        buffer_id: &str,
        deny: &DenyList,
    ) -> Result<Registered> {
        let no = |why: &str| Registered {
            doc: 0,
            tracked: false,
            reason: Some(why.to_owned()),
        };
        if matches!(deny.check(&tree.root.join(rel)), Verdict::Denied { .. }) {
            return Ok(no("personal"));
        }
        if is_secret(rel) {
            return Ok(no("secret"));
        }
        if blob::is_ignored(&tree.git_dir, &tree.root, rel) {
            return Ok(no("ignored"));
        }
        let mut g = self.lock();
        let branch = g.h.branch(
            &tree.branch_name(),
            BranchKind::Worktree,
            tree.base.as_deref(),
        )?;
        let doc = g.h.doc_for(rel)?;
        g.h.activate(doc, branch, || {
            Ok(super::capture::base_text(tree, rel).unwrap_or_default())
        })?;
        g.buffers
            .insert(buffer_id.to_owned(), Buffer { doc, branch });
        Ok(Registered {
            doc: doc.0,
            tracked: true,
            reason: None,
        })
    }

    /// Apply CHANGES to BUFFER_ID's document, each as its origin's peer.  Refused as `split-required` when they insert
    /// more than [`BATCH_MAX`] bytes.  The document's text must then hash to REGION_HASH, else the buffer is out of
    /// step and wants a `resync`.
    pub fn batch(
        &self,
        buffer_id: &str,
        changes: &[BatchChange],
        region_hash: &str,
        now: f64,
    ) -> Result<BatchReply> {
        if changes.iter().map(|c| c.inserted.len()).sum::<usize>() > BATCH_MAX {
            return Err(Error::Refused("split-required".into()));
        }
        let mut g = self.lock();
        let (doc, branch) = {
            let b = g
                .buffers
                .get(buffer_id)
                .ok_or_else(|| Error::NotFound(format!("buffer {buffer_id}")))?;
            (b.doc, b.branch)
        };
        let mut spans = Vec::new();
        for c in changes {
            let (key, author) = author_of(&c.origin);
            let peer = g.peer(branch, &key, &author)?;
            let mut ad = g.h.activate(doc, branch, || Ok(String::new()))?;
            let ch = Change {
                start: c.start,
                old_len: c.old_len,
                inserted: c.inserted.clone(),
            };
            match ad.apply(peer, &ch) {
                Ok(s) => spans.extend(s.into_iter().map(|s| (peer, s))),
                // a change outside the text: the buffer is not the document
                Err(Error::Refused(_)) => return Ok(BatchReply::Resync),
                Err(e) => return Err(e),
            }
        }
        for (peer, s) in spans {
            g.settler.change(doc, peer, &[s], now);
        }
        let text = g.h.activate(doc, branch, || Ok(String::new()))?.text();
        Ok(if hash(&text) == region_hash {
            BatchReply::Ok
        } else {
            BatchReply::Resync
        })
    }

    /// The buffer's whole TEXT replaces the document's, as the user's change.
    pub fn resync(&self, buffer_id: &str, text: &str, now: f64) -> Result<()> {
        let mut g = self.lock();
        let (doc, branch) = {
            let b = g
                .buffers
                .get(buffer_id)
                .ok_or_else(|| Error::NotFound(format!("buffer {buffer_id}")))?;
            (b.doc, b.branch)
        };
        let (key, author) = author_of("user");
        let peer = g.peer(branch, &key, &author)?;
        let mut ad = g.h.activate(doc, branch, || Ok(String::new()))?;
        let old = ad.text();
        let mut spans = Vec::new();
        for ch in diff(&old, text) {
            spans.extend(ad.apply(peer, &ch)?);
        }
        g.settler.change(doc, peer, &spans, now);
        Ok(())
    }

    /// The buffer is no longer tracked.
    pub fn unregister(&self, buffer_id: &str) {
        self.lock().buffers.remove(buffer_id);
    }
}

#[cfg(test)]
mod tests {
    use super::super::{Hub, Tree};
    use super::*;
    use std::path::Path;

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
        home: tempfile::TempDir,
        _hist: tempfile::TempDir,
        hub: Hub,
        tree: Tree,
        deny: DenyList,
    }

    /// A project at HOME/proj with FILES committed, and the user's deny-list naming its `notes.org`.
    fn fx(files: &[(&str, &str)]) -> Fx {
        let home = tempfile::tempdir().unwrap();
        let root = home.path().join("proj");
        std::fs::create_dir_all(&root).unwrap();
        git(&root, &["init", "-q", "-b", "main"]);
        std::fs::write(root.join(".gitignore"), "ignored.txt\n").unwrap();
        for (p, t) in files {
            std::fs::write(root.join(p), t).unwrap();
        }
        git(&root, &["add", "."]);
        git(&root, &["commit", "-q", "-m", "base"]);
        let head = {
            let o = std::process::Command::new("git")
                .args(["rev-parse", "HEAD"])
                .current_dir(&root)
                .output()
                .unwrap();
            String::from_utf8(o.stdout).unwrap().trim().to_owned()
        };
        let cfg = home.path().join("config");
        std::fs::create_dir_all(&cfg).unwrap();
        let deny_file = cfg.join(norn::deny::DENY_FILE);
        std::fs::write(
            &deny_file,
            serde_json::json!({"version": 1, "entries": [{"kind": "file", "path": root.join("notes.org")}]}).to_string(),
        )
        .unwrap();
        std::fs::set_permissions(
            &deny_file,
            std::os::unix::fs::PermissionsExt::from_mode(0o600),
        )
        .unwrap();
        let deny = DenyList::load(home.path(), &cfg);
        let hist = tempfile::tempdir().unwrap();
        let hub = Hub::open(hist.path()).unwrap();
        let tree = Tree::new(&root, &root.join(".git"), Some(&head));
        Fx {
            home,
            _hist: hist,
            hub,
            tree,
            deny,
        }
    }

    fn change(start: usize, old_len: usize, inserted: &str, origin: &str) -> BatchChange {
        BatchChange {
            start,
            old_len,
            inserted: inserted.into(),
            origin: origin.into(),
        }
    }

    // pattern: D
    #[test]
    fn register_untracked_path_says_untracked() {
        let f = fx(&[("a.txt", "x\n")]);
        std::fs::write(f.tree.root.join("ignored.txt"), "i\n").unwrap();
        std::fs::write(f.tree.root.join(".env"), "KEY=1\n").unwrap();
        std::fs::write(f.tree.root.join("notes.org"), "mine\n").unwrap();
        for (path, why) in [
            ("ignored.txt", "ignored"),
            (".env", "secret"),
            ("notes.org", "personal"),
        ] {
            let r = f.hub.register(&f.tree, path, "b1", &f.deny).unwrap();
            assert!(!r.tracked, "{path}");
            assert_eq!(r.reason.as_deref(), Some(why), "{path}");
        }
        let r = f.hub.register(&f.tree, "a.txt", "b2", &f.deny).unwrap();
        assert!(r.tracked, "{r:?}");
        let _ = &f.home;
    }

    // pattern: D
    #[test]
    fn batch_applies_with_user_peer() {
        let f = fx(&[("a.txt", "one\n")]);
        f.hub.register(&f.tree, "a.txt", "b1", &f.deny).unwrap();
        let text = "one two\n";
        let reply = f
            .hub
            .batch("b1", &[change(3, 0, " two", "user")], &hash(text), 5.0)
            .unwrap();
        assert_eq!(reply, BatchReply::Ok);
        assert_eq!(f.hub.text(&f.tree, "a.txt").unwrap().as_deref(), Some(text));
        let who = f.hub.with(|h| {
            let n = h.count("peer").unwrap();
            h.author_of(verdandi::PeerId(n as u64)).unwrap().unwrap()
        });
        assert_eq!(who["kind"], "user");
    }

    // pattern: D
    #[test]
    fn hash_mismatch_asks_resync() {
        let f = fx(&[("a.txt", "one\n")]);
        f.hub.register(&f.tree, "a.txt", "b1", &f.deny).unwrap();
        let reply = f
            .hub
            .batch(
                "b1",
                &[change(3, 0, "!", "user")],
                &hash("not what the buffer has"),
                5.0,
            )
            .unwrap();
        assert_eq!(reply, BatchReply::Resync);
        // the editor then sends the whole text
        f.hub.resync("b1", "one!\n", 6.0).unwrap();
        assert_eq!(
            f.hub.text(&f.tree, "a.txt").unwrap().as_deref(),
            Some("one!\n")
        );
    }

    // pattern: D
    #[test]
    fn origin_merge_is_attributed_to_its_peer() {
        let f = fx(&[("a.txt", "one\n")]);
        f.hub.register(&f.tree, "a.txt", "b1", &f.deny).unwrap();
        f.hub
            .batch("b1", &[change(3, 0, "X", "agent:s9")], &hash("oneX\n"), 5.0)
            .unwrap();
        f.hub
            .batch("b1", &[change(4, 0, "Y", "user")], &hash("oneXY\n"), 6.0)
            .unwrap();
        let authors = f.hub.with(|h| {
            let n = h.count("peer").unwrap();
            (1..=n)
                .map(|i| h.author_of(verdandi::PeerId(i as u64)).unwrap().unwrap())
                .collect::<Vec<_>>()
        });
        assert!(
            authors
                .iter()
                .any(|a| a["kind"] == "agent" && a["session"] == "s9"),
            "{authors:?}"
        );
        assert!(authors.iter().any(|a| a["kind"] == "user"), "{authors:?}");
    }

    // pattern: D
    #[test]
    fn oversized_batch_refused() {
        let f = fx(&[("a.txt", "one\n")]);
        f.hub.register(&f.tree, "a.txt", "b1", &f.deny).unwrap();
        let big = "x".repeat(BATCH_MAX + 1);
        let e = f
            .hub
            .batch("b1", &[change(0, 0, &big, "user")], &hash("anything"), 5.0)
            .unwrap_err();
        assert!(e.to_string().contains("split-required"), "{e}");
        // nothing was applied
        assert_eq!(
            f.hub.text(&f.tree, "a.txt").unwrap().as_deref(),
            Some("one\n")
        );
    }
}

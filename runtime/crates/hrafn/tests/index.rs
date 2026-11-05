//! Tier 1 (the incremental index: chunks, FTS and symbols for the files whose blob changed) and the store side of
//! tier 2 (`missing`, `put_vectors`, `collect`, `lag`); in `fresh`, when tier 1 runs.
//!
//! test-pattern: the store tests and the git ones are pure (D): no clock and no timing; the store thread answers in
//! order and `git` runs to its exit. `fresh::git_event_waits_for_index_lock` is every-order (A) over the settle core.

use hrafn::{Class, CodeStore, Lang, Listed, Refresh, collect, lag, missing, put_vectors, refresh};
use std::collections::HashMap;
use std::io;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering};

const MODEL: &str = "m";
const DIMS: usize = 4;

fn el(path: &str, blob: &str) -> Listed {
    Listed {
        path: path.into(),
        blob: blob.into(),
        class: Class::Code,
        lang: Lang::Elisp,
        generated: false,
        size: 1,
    }
}

/// The files' bytes by path, and how often each was read.
struct Tree {
    files: Mutex<HashMap<String, String>>,
    reads: AtomicU32,
}

impl Tree {
    fn new(files: &[(&str, &str)]) -> Tree {
        Tree {
            files: Mutex::new(
                files
                    .iter()
                    .map(|(p, t)| (p.to_string(), t.to_string()))
                    .collect(),
            ),
            reads: AtomicU32::new(0),
        }
    }

    fn set(&self, path: &str, text: &str) {
        self.files.lock().unwrap().insert(path.into(), text.into());
    }

    fn read(&self, path: &str) -> io::Result<Vec<u8>> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        self.files
            .lock()
            .unwrap()
            .get(path)
            .map(|t| t.clone().into_bytes())
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
    }

    fn reads(&self) -> u32 {
        self.reads.swap(0, Ordering::SeqCst)
    }
}

async fn store() -> (tempfile::TempDir, CodeStore) {
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("code.db")).unwrap();
    (dir, s)
}

async fn run(s: &CodeStore, tree: &Tree, listed: &[Listed]) -> Refresh {
    refresh(s, listed, &|p: &str| tree.read(p), &[(MODEL, DIMS)])
        .await
        .unwrap()
}

/// A unit vector per key, made from the key's first bytes: the store does not care what it holds.
fn vectors(keys: &[([u8; 32], String)]) -> Vec<([u8; 32], Vec<f32>)> {
    keys.iter()
        .map(|(k, _)| {
            let v: Vec<f32> = k[..DIMS].iter().map(|b| f32::from(*b) + 1.0).collect();
            let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            (*k, v.into_iter().map(|x| x / n).collect())
        })
        .collect()
}

/// Embeds everything tier 2 would: what `missing` gives goes back through `put_vectors`.
async fn embed_all(s: &CodeStore) -> usize {
    let keys = missing(s, MODEL, 1000).await.unwrap();
    put_vectors(s, MODEL, &vectors(&keys)).await.unwrap();
    keys.len()
}

async fn ids_of(s: &CodeStore, path: &str) -> Vec<i64> {
    let path = path.to_string();
    s.handle()
        .read(move |c| {
            let mut q = c.prepare("select id from chunk where path = ?1 order by id")?;
            let ids = q
                .query_map([&path], |r| r.get(0))?
                .collect::<Result<Vec<i64>, _>>()?;
            Ok(ids)
        })
        .await
        .unwrap()
}

async fn vec_rows(s: &CodeStore) -> i64 {
    s.handle()
        .read(|c| Ok(c.query_row("select count(*) from vec", [], |r| r.get(0))?))
        .await
        .unwrap()
}

const A: &str = ";;; a.el\n(defun a-one () \"One.\" 1)\n\n(defun a-two () \"Two.\" 2)\n";
const B: &str = ";;; b.el\n(defvar b-var 1 \"A var.\")\n";

/// Pattern D.
#[tokio::test]
async fn second_refresh_touches_nothing() {
    let (_d, s) = store().await;
    let tree = Tree::new(&[("a.el", A), ("b.el", B)]);
    let listed = [el("a.el", "blob-a"), el("b.el", "blob-b")];
    let first = run(&s, &tree, &listed).await;
    assert_eq!(first.files_changed, 2);
    assert!(first.chunks_written >= 2);
    assert_eq!(first.keys_missing, first.chunks_written);
    assert_eq!(tree.reads(), 2);
    let ids = ids_of(&s, "a.el").await;

    let second = run(&s, &tree, &listed).await;
    assert_eq!(
        (second.files_changed, second.chunks_written),
        (0, 0),
        "{second:?}"
    );
    assert_eq!(second.keys_missing, first.keys_missing);
    assert_eq!(tree.reads(), 0, "an unchanged blob is not even read");
    assert_eq!(ids_of(&s, "a.el").await, ids);
    let l = lag(&s, Some(MODEL)).await.unwrap();
    assert_eq!(l.chunks_behind, first.keys_missing);
    assert_eq!(l.files_behind, 2);
}

/// Pattern D. A branch switch and back: content keys make the second switch embed nothing.
#[tokio::test]
async fn branch_back_and_forth_embeds_nothing() {
    let (_d, s) = store().await;
    let tree = Tree::new(&[("a.el", A)]);
    run(&s, &tree, &[el("a.el", "main")]).await;
    let on_main = embed_all(&s).await;
    assert!(on_main >= 1);

    let other = ";;; a.el\n(defun a-other () \"Other.\" 3)\n";
    tree.set("a.el", other);
    let switched = run(&s, &tree, &[el("a.el", "topic")]).await;
    assert_eq!(switched.files_changed, 1);
    assert_eq!(embed_all(&s).await, 1, "only the topic branch's chunk");

    tree.set("a.el", A);
    let back = run(&s, &tree, &[el("a.el", "main")]).await;
    assert_eq!(back.files_changed, 1, "the rows are rebuilt");
    assert_eq!(back.keys_missing, 0, "and nothing is embedded again");
    assert!(missing(&s, MODEL, 1000).await.unwrap().is_empty());
    assert_eq!(lag(&s, Some(MODEL)).await.unwrap().chunks_behind, 0);
}

/// Pattern D.
#[tokio::test]
async fn changed_file_only_rewritten() {
    let (_d, s) = store().await;
    let tree = Tree::new(&[("a.el", A), ("b.el", B)]);
    run(&s, &tree, &[el("a.el", "a1"), el("b.el", "b1")]).await;
    let b_ids = ids_of(&s, "b.el").await;
    let a_ids = ids_of(&s, "a.el").await;
    tree.reads();

    tree.set("a.el", ";;; a.el\n(defun a-one () \"One, changed.\" 1)\n");
    let r = run(&s, &tree, &[el("a.el", "a2"), el("b.el", "b1")]).await;
    assert_eq!(r.files_changed, 1);
    assert_eq!(tree.reads(), 1);
    assert_eq!(ids_of(&s, "b.el").await, b_ids, "b.el's rows untouched");
    assert_ne!(ids_of(&s, "a.el").await, a_ids);

    // a file gone from the list goes from the store
    let r = run(&s, &tree, &[el("a.el", "a2")]).await;
    assert_eq!(r.files_changed, 1);
    assert!(ids_of(&s, "b.el").await.is_empty());
}

/// Pattern D. Unreferenced keys are kept up to 2× the live set, least recently referenced first out.
#[tokio::test]
async fn collect_keeps_two_x() {
    let (_d, s) = store().await;
    let version = |n: u32| format!(";;; a.el\n(defun a-{n} () \"Version {n}.\" {n})\n");
    let tree = Tree::new(&[("a.el", &version(1))]);
    for n in 1..=5 {
        tree.set("a.el", &version(n));
        run(&s, &tree, &[el("a.el", &format!("v{n}"))]).await;
        assert_eq!(embed_all(&s).await, 1);
    }
    assert_eq!(vec_rows(&s).await, 5, "one live key, four unreferenced");
    assert_eq!(collect(&s, MODEL).await.unwrap(), 2, "v1 and v2 go");
    assert_eq!(vec_rows(&s).await, 3);
    assert_eq!(
        collect(&s, MODEL).await.unwrap(),
        0,
        "a second pass removes nothing"
    );

    // v4 and v3 were kept: switching back to them embeds nothing; v1 went
    for (n, behind) in [(4, 0), (3, 0), (1, 1)] {
        tree.set("a.el", &version(n));
        let r = run(&s, &tree, &[el("a.el", &format!("v{n}"))]).await;
        assert_eq!(r.keys_missing, behind, "v{n}");
    }
    // the live key is never collected, however old: v1 is live now, the oldest key, and stays
    embed_all(&s).await;
    collect(&s, MODEL).await.unwrap();
    assert!(missing(&s, MODEL, 1000).await.unwrap().is_empty());
}

mod fresh {
    use super::*;
    use hrafn::fresh::{Due, Fresh, Settle, diff};
    use hrafn::{Config, GitCli, list};
    use skuld::{Core, Partial, events};
    use std::path::Path;
    use std::process::Command;
    use std::time::Duration;

    fn git(dir: &Path, args: &[&str]) {
        let st = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(args)
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    }

    fn repo(files: &[(&str, &str)]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        git(dir.path(), &["init", "-q"]);
        for (p, c) in files {
            std::fs::write(dir.path().join(p), c).unwrap();
        }
        git(dir.path(), &["add", "-A"]);
        git(dir.path(), &["commit", "-q", "-m", "one"]);
        dir
    }

    fn listed(dir: &Path, config: &Config) -> Vec<Listed> {
        list(dir, &GitCli, config, &|_: &str| true).unwrap()
    }

    async fn index(s: &CodeStore, dir: &Path, l: &[Listed]) -> Refresh {
        let read = |p: &str| std::fs::read(dir.join(p));
        refresh(s, l, &read, &[(MODEL, DIMS)]).await.unwrap()
    }

    /// Pattern D.
    #[tokio::test]
    async fn uncommitted_edit_counts() {
        let d = repo(&[("a.el", A)]);
        let (_s, s) = store().await;
        let first = listed(d.path(), &Config::default());
        index(&s, d.path(), &first).await;

        std::fs::write(d.path().join("a.el"), format!("{A}(defun a-three () 3)\n")).unwrap();
        let edited = listed(d.path(), &Config::default());
        assert_ne!(
            edited[0].blob, first[0].blob,
            "the working tree's content counts"
        );
        let r = index(&s, d.path(), &edited).await;
        assert_eq!(r.files_changed, 1);
        assert!(r.keys_missing > 0);
    }

    /// Pattern D.
    #[tokio::test]
    async fn excluded_only_commit_is_not_stale() {
        let d = repo(&[("a.el", A), ("notes.txt", "one\n")]);
        let config = Config {
            exclude: vec!["*.txt".into()],
            ..Config::default()
        };
        let (_s, s) = store().await;
        index(&s, d.path(), &listed(d.path(), &config)).await;

        std::fs::write(d.path().join("notes.txt"), "two\n").unwrap();
        git(d.path(), &["commit", "-q", "-am", "notes only"]);
        let now = listed(d.path(), &config);
        assert!(diff(&s, &now, 1000).await.unwrap().is_empty());
        assert_eq!(index(&s, d.path(), &now).await.files_changed, 0);
    }

    /// Pattern D. Without watches, the query's own diff of blobs finds the edit.
    #[tokio::test]
    async fn no_watches_falls_back_to_the_hash_diff() {
        let d = repo(&[("a.el", A), ("b.el", B)]);
        let (_s, s) = store().await;
        index(&s, d.path(), &listed(d.path(), &Config::default())).await;
        assert!(
            diff(&s, &listed(d.path(), &Config::default()), 1000)
                .await
                .unwrap()
                .is_empty()
        );

        std::fs::write(d.path().join("b.el"), ";;; b.el\n(defvar b-var 2)\n").unwrap();
        std::fs::remove_file(d.path().join("a.el")).unwrap();
        let now = listed(d.path(), &Config::default());
        let changes = diff(&s, &now, 1000).await.unwrap();
        assert_eq!(changes.changed, ["b.el"]);
        assert_eq!(changes.gone, ["a.el"]);
        // the diff is bounded: past its limit it says so, and the caller refreshes everything
        let capped = diff(&s, &now, 1).await.unwrap();
        assert!(capped.capped);
        assert_eq!(index(&s, d.path(), &now).await.files_changed, 2);
    }

    const QUIET: Duration = Duration::from_millis(2000);

    #[derive(Clone, Debug)]
    enum Ev {
        /// A change under the gitdir (HEAD, index, refs).
        Git,
        /// `index.lock` appeared (true) or went (false).
        Lock(bool),
        /// The clock reads this many ms.
        At(u64),
    }
    events!(Ev { Git, Lock, At });

    /// The settle core, recording every refresh it calls for and the state it called for it in.
    struct Probe {
        settle: Settle,
        now: Duration,
        locked: bool,
        last_git: Option<Duration>,
        dues: Vec<(Duration, bool, Option<Duration>)>,
    }

    impl Core for Probe {
        type Event = Ev;
        fn step(&mut self, ev: Ev) -> Vec<Ev> {
            let fed = match ev {
                Ev::Git => {
                    self.last_git = Some(self.now);
                    Fresh::Git
                }
                Ev::Lock(on) => {
                    self.locked = on;
                    Fresh::Lock(on)
                }
                Ev::At(ms) => {
                    self.now = Duration::from_millis(ms);
                    Fresh::At(self.now)
                }
            };
            if let Some(Due::All) = self.settle.feed(fed) {
                self.dues.push((self.now, self.locked, self.last_git));
                self.last_git = None;
            }
            vec![]
        }
    }

    /// Pattern A. A checkout writes HEAD and the index under `index.lock`: in every order of those writes, the lock and
    /// the clock, a refresh is called for only once the lock is gone and the gitdir has been quiet for the period, and
    /// the last write is always followed by one.
    #[test]
    fn git_event_waits_for_index_lock() {
        let mut p = Partial::new();
        let git = p.source("gitdir", vec![Ev::Git, Ev::Git]);
        let lock = p.source("lock", vec![Ev::Lock(true), Ev::Lock(false)]);
        let clock = p.source("clock", vec![Ev::At(500), Ev::At(1500), Ev::At(9000)]);
        // the shell's claims: git takes the lock before it writes, drops it after; the last reading comes last
        p.before((lock, 0), (git, 0))
            .before((git, 1), (lock, 1))
            .before((git, 1), (clock, 2))
            .before((lock, 1), (clock, 2));
        let report = skuld::every_order(
            &p,
            skuld::Bound::default(),
            || Probe {
                settle: Settle::new(QUIET, Duration::from_secs(30)),
                now: Duration::ZERO,
                locked: false,
                last_git: None,
                dues: vec![],
            },
            |probe, _| {
                for (at, locked, last) in &probe.dues {
                    if *locked {
                        return Err(format!("a refresh at {at:?} while index.lock is there"));
                    }
                    let last = last.ok_or(format!("a refresh at {at:?} with no git change"))?;
                    if *at < last + QUIET {
                        return Err(format!("a refresh at {at:?}, {last:?} + quiet not reached"));
                    }
                }
                if probe.last_git.is_some() {
                    return Err("the last change was never followed by a refresh".into());
                }
                Ok(())
            },
        );
        assert!(report.orders > 1, "{report:?}");
    }
}

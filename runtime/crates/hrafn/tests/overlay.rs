//! The overlay core (H16 overlay design §2, §5.1 item 4, §5.3): seeds, re-diffs and re-checks of a worktree against
//! the base, the base's transitions applied to every tree in the base's own batch, and per-view admission. Each test
//! compares the store's rows with the invariant computed independently from the checkouts on disk:
//! `overlay(T) = { p ↦ adm_T(p) : adm_T(p) ≠ adm_base(p) }`, where `adm` is `files::list`'s answer.
//!
//! test-pattern: pure (D) but `overlay_matches_blob_diff_in_every_order` (E, `skuld`): the store thread answers in
//! order, git runs to completion, nothing here has a clock or a timeout.

use hrafn::overlay::{self, Cx};
use hrafn::{
    CodeStore, Config, DoorKind, GitCli, GixDoor, Listed, TreeGit, TreeId, TreeState, list, refresh,
};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

fn git_out(dir: &Path, args: &[&str]) -> String {
    let o = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        o.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8_lossy(&o.stdout).trim().to_string()
}

fn write(root: &Path, files: &[(&str, &str)]) {
    for (p, c) in files {
        let f = root.join(p);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(f, c).unwrap();
    }
}

fn remove(root: &Path, p: &str) {
    std::fs::remove_file(root.join(p)).unwrap();
}

fn commit(root: &Path, msg: &str) -> String {
    git_out(root, &["add", "-A"]);
    git_out(root, &["commit", "-q", "--allow-empty", "-m", msg]);
    git_out(root, &["rev-parse", "HEAD"])
}

const ALLOW_ALL: fn(&str) -> bool = |_| true;

/// A main checkout with FILES committed, and a linked worktree `t` on its own branch.
struct Fixture {
    _dir: tempfile::TempDir,
    main: PathBuf,
    t: PathBuf,
    store: CodeStore,
    tree: TreeId,
    config: Config,
    allow: fn(&str) -> bool,
}

impl Fixture {
    async fn new(files: &[(&str, &str)], config: Config, allow: fn(&str) -> bool) -> Fixture {
        // under the temp dir's real path: a root with a link in its path is refused
        let dir = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let main = dir.path().join("main");
        std::fs::create_dir(&main).unwrap();
        git_out(&main, &["init", "-q", "-b", "main"]);
        write(&main, files);
        commit(&main, "one");
        let t = dir.path().join("t");
        git_out(
            &main,
            &["worktree", "add", "-q", "-b", "t", t.to_str().unwrap()],
        );
        let store = CodeStore::open(&dir.path().join("code.db")).unwrap();
        let gitdir = git_out(&t, &["rev-parse", "--git-dir"]);
        let tree = store
            .tree_open("wt-t", t.to_str().unwrap(), &gitdir, DoorKind::Cli)
            .await
            .unwrap();
        let f = Fixture {
            _dir: dir,
            main,
            t,
            store,
            tree,
            config,
            allow,
        };
        f.refresh_base().await;
        f
    }

    fn listed(&self, root: &Path) -> Vec<Listed> {
        list(root, &GitCli, &self.config, &self.allow).unwrap()
    }

    /// Tier 1 over main's working tree, and the commit it was built from.
    async fn refresh_base(&self) {
        let listed = self.listed(&self.main);
        let main = self.main.clone();
        refresh(
            &self.store,
            &listed,
            &move |p: &str| std::fs::read(main.join(p)),
            &[],
        )
        .await
        .unwrap();
        let head = git_out(&self.main, &["rev-parse", "HEAD"]);
        self.store
            .meta_set(hrafn::index::META_BUILT_FROM, &head)
            .await
            .unwrap();
    }

    fn cx<'a>(&'a self, door: &'a (dyn TreeGit + Sync)) -> Cx<'a> {
        Cx {
            store: &self.store,
            tree: self.tree,
            root: &self.t,
            door,
            config: &self.config,
            allow: &self.allow,
        }
    }

    async fn rows(&self) -> BTreeMap<String, Option<String>> {
        let t = self.tree.0;
        self.store
            .handle()
            .read(move |c| {
                let mut st = c.prepare("select path, blob from file where tree = ?1")?;
                Ok(st
                    .query_map([t], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<Result<_, _>>()?)
            })
            .await
            .unwrap()
    }

    /// The invariant, from the checkouts: T's admitted blob wherever it differs from the base's.
    fn expected(&self) -> BTreeMap<String, Option<String>> {
        let blobs = |root: &Path| -> BTreeMap<String, String> {
            self.listed(root)
                .into_iter()
                .map(|l| (l.path, l.blob))
                .collect()
        };
        let (base, t) = (blobs(&self.main), blobs(&self.t));
        let mut out = BTreeMap::new();
        for p in base.keys().chain(t.keys()) {
            if base.get(p) != t.get(p) {
                out.insert(p.clone(), t.get(p).cloned());
            }
        }
        out
    }

    /// Every `(path, blob)` a row names has its chunks.
    async fn content_complete(&self) -> Result<(), String> {
        let missing: Vec<(i64, String, String)> = self
            .store
            .handle()
            .read(|c| {
                let mut st = c.prepare(
                    "select f.tree, f.path, f.blob from file f where f.blob is not null and not exists
                       (select 1 from chunk c where c.path = f.path and c.blob = f.blob)",
                )?;
                Ok(st
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                    .collect::<Result<_, _>>()?)
            })
            .await
            .unwrap();
        if missing.is_empty() {
            Ok(())
        } else {
            Err(format!("rows without content: {missing:?}"))
        }
    }

    async fn at_invariant(&self) -> Result<(), String> {
        let (rows, want) = (self.rows().await, self.expected());
        if rows != want {
            return Err(format!("rows {rows:?}\n want {want:?}"));
        }
        self.content_complete().await
    }

    async fn state(&self) -> TreeState {
        let t = self.tree;
        self.store
            .trees()
            .await
            .unwrap()
            .into_iter()
            .find(|r| r.id == t)
            .unwrap()
            .state
    }
}

const FILES: &[(&str, &str)] = &[
    ("a.txt", "alpha\n"),
    ("b.txt", "beta\n"),
    ("c.txt", "gamma\n"),
    ("d.txt", "delta\n"),
];

async fn fixture() -> Fixture {
    Fixture::new(FILES, Config::default(), ALLOW_ALL).await
}

/// Pattern E. Base transitions (an edit and a deletion in main's working tree, then a commit there), tree versions (an
/// edit with its feed hints, a commit with its re-diff), and a seed and a re-diff, in every order: the end state is
/// the invariant, computed from the checkouts.
#[test]
fn overlay_matches_blob_diff_in_every_order() {
    use skuld::{Core, Partial, events};

    #[derive(Clone, Debug)]
    enum Ev {
        BaseEdit,
        BaseCommit,
        TreeEdit,
        TreeCommit,
        Seed,
        Rediff,
        Hint(Vec<String>),
    }
    events!(Ev {
        BaseEdit,
        BaseCommit,
        TreeEdit,
        TreeCommit,
        Seed,
        Rediff,
        Hint
    });

    struct Probe {
        rt: tokio::runtime::Runtime,
        f: Fixture,
    }

    impl Core for Probe {
        type Event = Ev;
        fn step(&mut self, ev: Ev) -> Vec<Ev> {
            let f = &self.f;
            self.rt.block_on(async {
                let cx = f.cx(&GitCli);
                match ev {
                    Ev::BaseEdit => {
                        write(&f.main, &[("b.txt", "beta-main\n")]);
                        remove(&f.main, "d.txt");
                        f.refresh_base().await;
                        vec![]
                    }
                    Ev::BaseCommit => {
                        write(&f.main, &[("c.txt", "gamma-main\n")]);
                        commit(&f.main, "base");
                        f.refresh_base().await;
                        vec![]
                    }
                    Ev::TreeEdit => {
                        write(&f.t, &[("b.txt", "beta-t\n"), ("d.txt", "delta-t\n")]);
                        vec![Ev::Hint(vec!["b.txt".into(), "d.txt".into()])]
                    }
                    Ev::TreeCommit => {
                        write(&f.t, &[("c.txt", "gamma-main\n")]);
                        commit(&f.t, "tree");
                        vec![Ev::Rediff]
                    }
                    Ev::Seed => {
                        overlay::seed(&cx).await.unwrap();
                        vec![]
                    }
                    Ev::Rediff => {
                        overlay::rediff(&cx).await.unwrap();
                        vec![]
                    }
                    Ev::Hint(paths) => {
                        overlay::recheck(&cx, &paths).await.unwrap();
                        vec![]
                    }
                }
            })
        }
    }

    let mut p = Partial::new();
    p.source("base", vec![Ev::BaseEdit, Ev::BaseCommit]);
    p.source("tree", vec![Ev::TreeEdit, Ev::TreeCommit]);
    p.source("overlay", vec![Ev::Seed, Ev::Rediff]);
    let report = skuld::every_order(
        &p,
        skuld::Bound::default(),
        || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            let f = rt.block_on(async {
                let f = fixture().await;
                // T's own committed change and an untracked file, there before any event
                write(&f.t, &[("a.txt", "alpha-t\n")]);
                commit(&f.t, "t");
                write(&f.t, &[("u.txt", "untracked\n")]);
                f
            });
            Probe { rt, f }
        },
        |probe, _| probe.rt.block_on(probe.f.at_invariant()),
    );
    assert_eq!(report.orders, 90);
}

/// Pattern D. A base change of p under a tree with no row for p: the base's batch inserts T's row naming the old
/// content (one `file` insert, no read of T's file), and the old content's chunks stay as they were.
#[tokio::test]
async fn transition_inserts_row_without_reading() {
    let f = fixture().await;
    overlay::seed(&f.cx(&GitCli)).await.unwrap();
    assert!(f.rows().await.is_empty(), "T equals the base");
    let old = git_out(&f.main, &["rev-parse", "HEAD:b.txt"]);
    let ids_before = chunk_ids(&f.store, "b.txt", &old).await;
    assert!(!ids_before.is_empty());
    // T's copy can't be read: a transition must not try
    std::fs::rename(f.t.join("b.txt"), f.t.join("b.moved")).unwrap();
    write(&f.main, &[("b.txt", "beta-main\n")]);
    f.refresh_base().await;
    assert_eq!(
        f.rows().await,
        BTreeMap::from([("b.txt".to_string(), Some(old.clone()))])
    );
    assert_eq!(chunk_ids(&f.store, "b.txt", &old).await, ids_before);
    f.content_complete().await.unwrap();
}

async fn chunk_ids(s: &CodeStore, path: &str, blob: &str) -> Vec<i64> {
    let (p, b) = (path.to_string(), blob.to_string());
    s.handle()
        .read(move |c| {
            let mut st =
                c.prepare("select id from chunk where path = ?1 and blob = ?2 order by id")?;
            Ok(st
                .query_map([p, b], |r| r.get(0))?
                .collect::<Result<_, _>>()?)
        })
        .await
        .unwrap()
}

/// Pattern D. Admission runs on each view's own bytes: p over 1 MiB in T but not in the base is a tombstone in T; q
/// over 1 MiB in the base but not in T is a row.
#[tokio::test]
async fn content_admission_per_view() {
    let big = "x\n".repeat(600 * 1024);
    let f = Fixture::new(
        &[("p.txt", "small p\n"), ("q.txt", &big)],
        Config::default(),
        ALLOW_ALL,
    )
    .await;
    write(&f.t, &[("p.txt", &big), ("q.txt", "small q\n")]);
    overlay::seed(&f.cx(&GitCli)).await.unwrap();
    let rows = f.rows().await;
    assert_eq!(rows.get("p.txt"), Some(&None), "{rows:?}");
    assert!(matches!(rows.get("q.txt"), Some(Some(_))), "{rows:?}");
    f.at_invariant().await.unwrap();
}

/// Pattern D. p deleted in main's working tree (still in the commit the base was built from, and in T): T gets a row.
#[tokio::test]
async fn main_working_tree_deletion_overlaid() {
    let f = fixture().await;
    remove(&f.main, "c.txt");
    f.refresh_base().await;
    overlay::seed(&f.cx(&GitCli)).await.unwrap();
    let rows = f.rows().await;
    assert!(matches!(rows.get("c.txt"), Some(Some(_))), "{rows:?}");
    f.at_invariant().await.unwrap();
}

/// Pattern D. T edits p, then `git checkout -- p` (HEAD stays): after the re-diff, no row.
#[tokio::test]
async fn clean_again_without_head_move() {
    let f = fixture().await;
    write(&f.t, &[("b.txt", "beta-t\n")]);
    overlay::seed(&f.cx(&GitCli)).await.unwrap();
    assert!(f.rows().await.contains_key("b.txt"));
    git_out(&f.t, &["checkout", "--", "b.txt"]);
    overlay::rediff(&f.cx(&GitCli)).await.unwrap();
    assert!(f.rows().await.is_empty(), "{:?}", f.rows().await);
    assert_eq!(f.state().await, TreeState::Live);
}

/// Pattern D. T edited back to the base's content: no row.
#[tokio::test]
async fn equal_content_drops_the_row() {
    let f = fixture().await;
    write(&f.t, &[("b.txt", "beta-t\n")]);
    overlay::seed(&f.cx(&GitCli)).await.unwrap();
    assert!(f.rows().await.contains_key("b.txt"));
    write(&f.t, &[("b.txt", "beta\n")]);
    overlay::recheck(&f.cx(&GitCli), &["b.txt".to_string()])
        .await
        .unwrap();
    assert!(f.rows().await.is_empty(), "{:?}", f.rows().await);
}

/// Pattern D. A path `.gitattributes` names a conversion for, in a touched tree (the gix door hashes raw bytes): its
/// row is written even where its content equals the base's, and it names the bytes T has.
#[tokio::test]
async fn uncertain_blob_writes_the_row() {
    let f = Fixture::new(
        &[
            (".gitattributes", "*.txt text eol=lf\n"),
            ("a.txt", "alpha\n"),
            ("b.txt", "beta\n"),
        ],
        Config::default(),
        ALLOW_ALL,
    )
    .await;
    // the checkout's index is racy (files as new as it): backdate them and refresh it, so b.txt is stat-clean
    let then = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000_000);
    for p in ["a.txt", "b.txt"] {
        let file = std::fs::File::options()
            .write(true)
            .open(f.t.join(p))
            .unwrap();
        file.set_modified(then).unwrap();
    }
    git_out(&f.t, &["update-index", "-q", "--refresh"]);
    write(&f.t, &[("a.txt", "alpha-t\n")]);
    overlay::seed(&f.cx(&GixDoor)).await.unwrap();
    let rows = f.rows().await;
    assert!(rows.contains_key("a.txt"), "{rows:?}");
    // b.txt is stat-clean and committed: its blob is the index's, certain
    assert!(!rows.contains_key("b.txt"), "{rows:?}");
    let raw = git_out(&f.t, &["hash-object", "--no-filters", "a.txt"]);
    assert_eq!(rows["a.txt"].as_deref(), Some(raw.as_str()));
    // b.txt edited back to the base's content, read through the gix door: uncertain, so a row
    write(&f.t, &[("b.txt", "beta-t\n")]);
    write(&f.t, &[("b.txt", "beta\n")]);
    overlay::recheck(&f.cx(&GixDoor), &["b.txt".to_string()])
        .await
        .unwrap();
    assert!(f.rows().await.contains_key("b.txt"));
    f.content_complete().await.unwrap();
}

/// Pattern D. A seed stopped after its first batch (its rows written, its final transaction not, one of them stale by
/// the time it resumes): on open the tree is `seeding`; the seed runs again and ends at the invariant.
#[tokio::test]
async fn crash_mid_seed_reseeds() {
    let f = fixture().await;
    write(&f.t, &[("b.txt", "beta-t\n"), ("c.txt", "gamma-t\n")]);
    // the first batch's rows as a seed wrote them: b.txt right, c.txt from an older edit
    overlay::recheck(&f.cx(&GitCli), &["b.txt".to_string(), "c.txt".to_string()])
        .await
        .unwrap();
    assert_eq!(f.rows().await.len(), 2);
    write(&f.t, &[("c.txt", "gamma-t2\n")]);
    // a restart: the registry and the rows persist
    let Fixture {
        _dir,
        main,
        t,
        store,
        tree,
        config,
        allow,
    } = f;
    let path = _dir.path().join("code.db");
    std::thread::spawn(move || store.shutdown()).join().unwrap();
    let store = CodeStore::open(&path).unwrap();
    let f = Fixture {
        _dir,
        main,
        t,
        store,
        tree,
        config,
        allow,
    };
    assert_eq!(f.state().await, TreeState::Seeding);
    overlay::seed(&f.cx(&GitCli)).await.unwrap();
    assert_eq!(f.state().await, TreeState::Live);
    f.at_invariant().await.unwrap();
}

/// Pattern D. A deny-listed file and a `Config`-excluded file that differ in T get no row in any view; a plain file
/// that differs does.
#[tokio::test]
async fn excluded_file_absent_in_every_view() {
    let f = Fixture::new(
        &[
            ("ok.txt", "ok\n"),
            ("deny.txt", "deny\n"),
            ("skip/x.txt", "skip\n"),
        ],
        Config {
            exclude: vec!["skip/**".into()],
            ..Config::default()
        },
        |p| p != "deny.txt",
    )
    .await;
    write(
        &f.t,
        &[
            ("ok.txt", "ok-t\n"),
            ("deny.txt", "deny-t\n"),
            ("skip/x.txt", "skip-t\n"),
            ("skip/new.txt", "new\n"),
        ],
    );
    overlay::seed(&f.cx(&GitCli)).await.unwrap();
    let rows = f.rows().await;
    assert_eq!(rows.keys().collect::<Vec<_>>(), ["ok.txt"], "{rows:?}");
    let base: Vec<String> = f
        .store
        .handle()
        .read(|c| {
            let mut st = c.prepare("select path from file where tree = 0 order by path")?;
            Ok(st.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?)
        })
        .await
        .unwrap();
    assert_eq!(base, ["ok.txt"]);
    f.at_invariant().await.unwrap();
}

/// Pattern D. A link is never admitted, in any view, through either door (the CLI's `hash-object` would hash the
/// target's content, gix the target's name): the rule is decided from the entry's mode or `lstat` before any hash. A
/// file T turned into a link is a tombstone; a new link is no row; a committed link is no row.
#[tokio::test]
async fn links_are_never_admitted_by_either_door() {
    for (name, door) in [
        ("cli", Box::new(GitCli) as Box<dyn TreeGit + Sync>),
        ("gix", Box::new(GixDoor)),
    ] {
        let f = fixture().await;
        std::os::unix::fs::symlink("a.txt", f.main.join("l1")).unwrap();
        commit(&f.main, "a link");
        f.refresh_base().await;
        git_out(&f.t, &["merge", "-q", "--ff-only", "main"]);
        remove(&f.t, "b.txt");
        std::os::unix::fs::symlink("a.txt", f.t.join("b.txt")).unwrap();
        std::os::unix::fs::symlink("c.txt", f.t.join("l2")).unwrap();
        write(&f.t, &[("d.txt", "delta-t\n")]);
        overlay::seed(&f.cx(door.as_ref())).await.unwrap();
        let rows = f.rows().await;
        assert_eq!(rows.get("b.txt"), Some(&None), "{name}: {rows:?}");
        assert!(!rows.contains_key("l1"), "{name}: {rows:?}");
        assert!(!rows.contains_key("l2"), "{name}: {rows:?}");
        assert!(rows.contains_key("d.txt"), "{name}: {rows:?}");
        f.at_invariant().await.unwrap();
    }
}

/// Pattern D. The base moves p to content a tree already stores: tier 1 neither reads p nor chunks it again (the
/// tree's chunk ids stay), and the tree's row, now equal to the base, goes.
#[tokio::test]
async fn base_refresh_reuses_tree_content() {
    let f = fixture().await;
    write(&f.t, &[("b.txt", "beta-shared\n")]);
    overlay::seed(&f.cx(&GitCli)).await.unwrap();
    let rows = f.rows().await;
    let Some(Some(blob)) = rows.get("b.txt").cloned() else {
        panic!("T's row of b.txt: {rows:?}");
    };
    let ids = chunk_ids(&f.store, "b.txt", &blob).await;
    assert!(!ids.is_empty());
    write(&f.main, &[("b.txt", "beta-shared\n")]);
    let listed = f.listed(&f.main);
    let main = f.main.clone();
    let reads = std::sync::Mutex::new(Vec::new());
    refresh(
        &f.store,
        &listed,
        &|p: &str| {
            reads.lock().unwrap().push(p.to_string());
            std::fs::read(main.join(p))
        },
        &[],
    )
    .await
    .unwrap();
    assert!(
        !reads.lock().unwrap().contains(&"b.txt".to_string()),
        "{:?}",
        reads.lock().unwrap()
    );
    assert_eq!(chunk_ids(&f.store, "b.txt", &blob).await, ids);
    assert!(f.rows().await.is_empty(), "{:?}", f.rows().await);
}

/// A door that rewrites PATH (once) just before it hashes: the file changes between the overlay's read and the hash.
struct Racing<'a> {
    inner: &'a (dyn TreeGit + Sync),
    file: PathBuf,
    text: &'static str,
    done: std::sync::atomic::AtomicBool,
}

impl TreeGit for Racing<'_> {
    fn kind(&self) -> DoorKind {
        self.inner.kind()
    }
    fn head(&self, root: &Path) -> std::io::Result<hrafn::Head> {
        self.inner.head(root)
    }
    fn tree_diff(&self, root: &Path, a: &str, b: &str) -> std::io::Result<Vec<hrafn::TreeChange>> {
        self.inner.tree_diff(root, a, b)
    }
    fn stat_status(&self, root: &Path) -> std::io::Result<hrafn::Status> {
        self.inner.stat_status(root)
    }
    fn ls_tree(&self, root: &Path, commit: &str) -> std::io::Result<Vec<hrafn::TreeEntry>> {
        self.inner.ls_tree(root, commit)
    }
    fn blobs(&self, root: &Path, paths: &[String]) -> std::io::Result<Vec<hrafn::Blob>> {
        if !self.done.swap(true, std::sync::atomic::Ordering::SeqCst) {
            std::fs::write(&self.file, self.text).unwrap();
        }
        self.inner.blobs(root, paths)
    }
    fn filtered(&self, root: &Path, paths: &[String]) -> std::io::Result<Vec<String>> {
        self.inner.filtered(root, paths)
    }
    fn as_git(&self) -> &dyn hrafn::Git {
        self.inner.as_git()
    }
}

/// Pattern D. A file written between the overlay's read and the door's hash: the row's blob and its chunks are of the
/// same bytes (the ones on disk last), never a blob of new bytes over chunks of old ones.
#[tokio::test]
async fn row_blob_matches_the_bytes_chunked() {
    let f = fixture().await;
    write(&f.t, &[("b.txt", "beta-before\n")]);
    let door = Racing {
        inner: &GitCli,
        file: f.t.join("b.txt"),
        text: "beta-after\n",
        done: false.into(),
    };
    overlay::seed(&f.cx(&door)).await.unwrap();
    f.at_invariant().await.unwrap();
    let rows = f.rows().await;
    let Some(Some(blob)) = rows.get("b.txt").cloned() else {
        panic!("T's row of b.txt: {rows:?}");
    };
    let text: String = f
        .store
        .handle()
        .read(move |c| {
            Ok(c.query_row(
                "select group_concat(embed_text, '') from chunk where path = 'b.txt' and blob = ?1",
                [blob],
                |r| r.get(0),
            )?)
        })
        .await
        .unwrap();
    assert!(text.contains("beta-after"), "{text:?}");
}

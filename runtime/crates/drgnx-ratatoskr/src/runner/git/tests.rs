use super::*;
use crate::matrix_gate::{ActionCtx, MatrixGate};
use norn::matrix::{Action, Role, Who};
use norn::store::CoordDb;
use urdr::graph::{Class, TxMeta};

struct Env {
    _dir: tempfile::TempDir,
    home: PathBuf,
    repo: PathBuf,
    root: PathBuf,
}

fn sh(env: &Path, dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("HOME", env)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.invalid")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.invalid")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn env() -> Env {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let repo = dir.path().join("repo");
    let root = dir.path().join("trees");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&repo).unwrap();
    sh(&home, &repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("x.txt"), "one\ntwo\nthree\n").unwrap();
    sh(&home, &repo, &["add", "-A"]);
    sh(&home, &repo, &["commit", "-q", "-m", "base"]);
    Env {
        _dir: dir,
        home,
        repo,
        root,
    }
}

fn commit(e: &Env, tree: &TaskTree, file: &str, body: &str) {
    let p = tree.path.join(file);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, body).unwrap();
    sh(&e.home, &tree.path, &["add", "-A"]);
    sh(&e.home, &tree.path, &["commit", "-q", "-m", file]);
}

fn base(e: &Env) -> String {
    sh(&e.home, &e.repo, &["rev-parse", "HEAD"])
        .trim()
        .to_owned()
}

#[derive(Default)]
struct Policy {
    marks: Mutex<BTreeMap<String, String>>,
    ci: Option<(CoordDb, MatrixGate)>,
}

impl GatePolicy for Policy {
    fn accepted(&self, _: &TaskTree) -> BTreeMap<String, String> {
        self.marks.lock().unwrap().clone()
    }
    fn ci_config<'a>(&'a self, _: &'a TaskTree, facts: Facts) -> GitFuture<'a, Gate> {
        Box::pin(async move {
            let (db, gate) = self.ci.clone().expect("a matrix");
            db.write(TxMeta::new("t", Class::System, "test"), move |tx| {
                let who = Who {
                    role: Some(Role::Worker),
                    ..Who::default()
                };
                let ctx = ActionCtx {
                    facts,
                    ..ActionCtx::default()
                };
                gate.check(tx, &who, Action::CodeCiConfig, &ctx, 1.0)
            })
            .await
            .map_err(|e| err("matrix", format!("{e:?}")))
        })
    }
}

fn hub(e: &Env, mode: TreeMode, p: Policy, db: Option<urdr::Handle>) -> HubGit {
    HubGit::new(e.root.clone(), mode, Box::new(p), db)
        .with_env(vec![("HOME".into(), e.home.to_string_lossy().into_owned())])
}

/// Accept every path of the task as it is now.
async fn accept_all(h: &HubGit, e: &Env, t: &TaskTree, marks: &Mutex<BTreeMap<String, String>>) {
    *marks.lock().unwrap() = h.diff_hashes(&e.repo, t).await.unwrap();
}

// Policies must be shared with the test to set marks: wrap in Arc through a small adapter.
struct Shared(std::sync::Arc<Policy>);
impl GatePolicy for Shared {
    fn accepted(&self, t: &TaskTree) -> BTreeMap<String, String> {
        self.0.accepted(t)
    }
    fn ci_config<'a>(&'a self, t: &'a TaskTree, f: Facts) -> GitFuture<'a, Gate> {
        self.0.ci_config(t, f)
    }
}

fn shared(
    e: &Env,
    mode: TreeMode,
    p: Policy,
    db: Option<urdr::Handle>,
) -> (HubGit, std::sync::Arc<Policy>) {
    let p = std::sync::Arc::new(p);
    let h = HubGit::new(e.root.clone(), mode, Box::new(Shared(p.clone())), db)
        .with_env(vec![("HOME".into(), e.home.to_string_lossy().into_owned())]);
    (h, p)
}

#[tokio::test]
async fn ci_workflow_change_is_a_card() {
    let e = env();
    let dbdir = tempfile::tempdir().unwrap();
    let db = CoordDb::spawn(dbdir.path().join("work.db"));
    let (h, p) = shared(
        &e,
        TreeMode::Worktree,
        Policy {
            ci: Some((db.clone(), MatrixGate::default())),
            ..Policy::default()
        },
        None,
    );
    let t = h
        .task_worktree(&e.repo, "r1", "t1", &base(&e))
        .await
        .unwrap();
    commit(&e, &t, ".github/workflows/ci.yml", "on: push\n");
    accept_all(&h, &e, &t, &p.marks).await;
    let g = h.merge_gate(&e.repo, &t).await.unwrap();
    assert!(matches!(g, Gate::Ask(_)), "{g:?}");
    // a plain source change is allowed
    let t2 = h
        .task_worktree(&e.repo, "r1", "t2", &base(&e))
        .await
        .unwrap();
    commit(&e, &t2, "src/a.rs", "fn a() {}\n");
    accept_all(&h, &e, &t2, &p.marks).await;
    assert_eq!(h.merge_gate(&e.repo, &t2).await.unwrap(), Gate::Allow);
    let n: i64 = db
        .write(TxMeta::new("t", Class::System, "test"), |tx| {
            Ok(tx
                .sql()
                .query_row("select count(*) from card where kind = 'matrix'", [], |r| {
                    r.get(0)
                })?)
        })
        .await
        .unwrap();
    assert_eq!(n, 1);
}

#[tokio::test]
async fn protected_config_change_refused() {
    let e = env();
    let (h, p) = shared(&e, TreeMode::Worktree, Policy::default(), None);
    let t = h
        .task_worktree(&e.repo, "r1", "t1", &base(&e))
        .await
        .unwrap();
    commit(&e, &t, ".claude/settings.json", "{}\n");
    accept_all(&h, &e, &t, &p.marks).await;
    match h.merge_gate(&e.repo, &t).await.unwrap() {
        Gate::Never(why) => assert!(why.contains(".claude/settings.json"), "{why}"),
        g => panic!("{g:?}"),
    }
}

#[tokio::test]
async fn tip_moved_after_check_refused() {
    let e = env();
    let (h, p) = shared(&e, TreeMode::Worktree, Policy::default(), None);
    let t = h
        .task_worktree(&e.repo, "r1", "t1", &base(&e))
        .await
        .unwrap();
    commit(&e, &t, "src/a.rs", "fn a() {}\n");
    // not accepted yet: waits
    assert!(matches!(
        h.merge_gate(&e.repo, &t).await.unwrap(),
        Gate::Never(_)
    ));
    accept_all(&h, &e, &t, &p.marks).await;
    assert_eq!(h.merge_gate(&e.repo, &t).await.unwrap(), Gate::Allow);
    commit(&e, &t, "src/b.rs", "fn b() {}\n");
    let r = h.merge(&e.repo, &t).await.unwrap_err();
    assert!(r.stderr.contains("moved"), "{r:?}");
    // the new diff is not accepted against its hash, and the old acceptance of a.rs does not cover b.rs
    assert!(matches!(
        h.merge_gate(&e.repo, &t).await.unwrap(),
        Gate::Never(_)
    ));
    accept_all(&h, &e, &t, &p.marks).await;
    assert_eq!(h.merge_gate(&e.repo, &t).await.unwrap(), Gate::Allow);
    assert_eq!(h.merge(&e.repo, &t).await.unwrap(), MergeOutcome::Merged);
    assert!(e.repo.join("src/b.rs").exists());
}

#[tokio::test]
async fn trial_shows_conflicts() {
    let e = env();
    let h = hub(&e, TreeMode::Worktree, Policy::default(), None);
    let b = base(&e);
    let a = h.task_worktree(&e.repo, "r1", "a", &b).await.unwrap();
    let c = h.task_worktree(&e.repo, "r1", "c", &b).await.unwrap();
    let d = h.task_worktree(&e.repo, "r1", "d", &b).await.unwrap();
    commit(&e, &a, "x.txt", "one\nA\nthree\n");
    commit(&e, &c, "x.txt", "one\nC\nthree\n");
    commit(&e, &d, "y.txt", "y\n");
    let r = h
        .trial_merge(&e.repo, &[a.branch.clone(), c.branch.clone()])
        .await
        .unwrap();
    assert!(!r.clean);
    assert_eq!(r.conflicts, vec![PathBuf::from("x.txt")]);
    let r = h
        .trial_merge(&e.repo, &[a.branch.clone(), d.branch.clone()])
        .await
        .unwrap();
    assert!(r.clean && r.conflicts.is_empty());
    // the scratch worktree is gone and the repo untouched
    assert!(!sh(&e.home, &e.repo, &["worktree", "list"]).contains(".trial"));
    assert_eq!(sh(&e.home, &e.repo, &["status", "--porcelain"]), "");
}

#[tokio::test]
async fn snapshot_bundle_fsck() {
    let e = env();
    let (h, p) = shared(&e, TreeMode::Snapshot, Policy::default(), None);
    let b = base(&e);
    let t = h.task_worktree(&e.repo, "r1", "t1", &b).await.unwrap();
    assert_eq!(t.mode, TreeMode::Snapshot);
    assert!(t.path.join("x.txt").exists());
    commit(&e, &t, "src/a.rs", "fn a() {}\n");
    h.write_bundle(&t, true).await.unwrap();
    // the gate reads the trusted repository only: the branch is imported, the folder is never looked at
    accept_all(&h, &e, &t, &p.marks).await;
    assert_eq!(h.merge_gate(&e.repo, &t).await.unwrap(), Gate::Allow);
    sh(
        &e.home,
        &e.repo,
        &["rev-parse", "--verify", &format!("refs/heads/{}", t.branch)],
    );
    // a damaged bundle is refused and no ref is written
    let t2 = h.task_worktree(&e.repo, "r1", "t2", &b).await.unwrap();
    commit(
        &e,
        &t2,
        "src/b.rs",
        "fn b() { /* padding padding padding */ }\n",
    );
    let bundle = h.write_bundle(&t2, true).await.unwrap();
    let mut bytes = std::fs::read(&bundle).unwrap();
    let n = bytes.len();
    bytes[n - 5] ^= 0xff;
    std::fs::write(&bundle, bytes).unwrap();
    assert!(h.inspect(&e.repo, &t2).await.is_err());
    let missing = std::process::Command::new("git")
        .args([
            "rev-parse",
            "--verify",
            "-q",
            &format!("refs/heads/{}", t2.branch),
        ])
        .current_dir(&e.repo)
        .env("HOME", &e.home)
        .status()
        .unwrap();
    assert!(!missing.success());
}

#[tokio::test]
async fn no_plain_git_in_a_ledger_folder() {
    let e = env();
    let dir = tempfile::tempdir().unwrap();
    let (store, db) = crate::runtime_db::open(dir.path()).unwrap();
    let h = hub(&e, TreeMode::Snapshot, Policy::default(), Some(db));
    let t = h
        .task_worktree(&e.repo, "r1", "t1", &base(&e))
        .await
        .unwrap();
    commit(&e, &t, "src/a.rs", "fn a() {}\n");
    assert!(
        h.write_bundle(&t, false).await.is_ok(),
        "an untouched folder"
    );
    h.touch(&t.path).await.unwrap();
    let r = h.write_bundle(&t, false).await.unwrap_err();
    assert!(r.stderr.contains("sandboxed"), "{r:?}");
    assert!(h.write_bundle(&t, true).await.is_ok());
    tokio::task::spawn_blocking(move || store.shutdown())
        .await
        .unwrap();
}

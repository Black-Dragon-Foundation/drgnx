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
    fn accepted<'a>(&'a self, _: &'a TaskTree) -> GitFuture<'a, BTreeMap<String, String>> {
        Box::pin(async move { Ok(self.marks.lock().unwrap().clone()) })
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
    fn accepted<'a>(&'a self, t: &'a TaskTree) -> GitFuture<'a, BTreeMap<String, String>> {
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

/// The empty `.envrc` and `mise.toml` the sandbox makes to pin them must not reach the user's checkout: a branch that
/// adds one (or really edits it) is refused at the gate, with the path on the card.
#[tokio::test]
async fn a_protected_file_stub_in_the_branch_is_refused() {
    let e = env();
    let (h, p) = shared(&e, TreeMode::Worktree, Policy::default(), None);
    let t = h
        .task_worktree(&e.repo, "r1", "t1", &base(&e))
        .await
        .unwrap();
    commit(&e, &t, ".envrc", "");
    commit(&e, &t, "src/a.rs", "fn a() {}\n");
    accept_all(&h, &e, &t, &p.marks).await;
    match h.merge_gate(&e.repo, &t).await.unwrap() {
        Gate::Never(why) => assert!(why.contains(".envrc") && !why.contains("a.rs"), "{why}"),
        g => panic!("{g:?}"),
    }
}

/// A snapshot task asked for again (a review begins, a mark is made) is the same tree: the agent's commits survive,
/// and its branch, which is not in the trusted repository yet, is found in the tree's own `.git`.  A manager's trial
/// merge of snapshot workers imports their branches first.
#[tokio::test]
async fn a_snapshot_task_is_not_remade_and_its_branch_is_imported_for_a_trial() {
    let e = env();
    let (h, _) = shared(&e, TreeMode::Snapshot, Policy::default(), None);
    let a = h
        .task_worktree(&e.repo, "r1", "a", &base(&e))
        .await
        .unwrap();
    commit(&e, &a, "a.txt", "A\n");
    let again = h
        .task_worktree(&e.repo, "r1", "a", &base(&e))
        .await
        .unwrap();
    assert_eq!(again, a);
    assert!(a.path.join("a.txt").is_file(), "the agent's work was reset");
    let b = h
        .task_worktree(&e.repo, "r1", "b", &base(&e))
        .await
        .unwrap();
    commit(&e, &b, "b.txt", "B\n");
    assert!(
        h.trial_merge(&e.repo, std::slice::from_ref(&a.branch))
            .await
            .is_err(),
        "a snapshot branch is not in the repository before it is imported"
    );
    for t in [&a, &b] {
        h.import(&e.repo, t).await.unwrap();
    }
    let r = h
        .trial_merge(&e.repo, &[a.branch.clone(), b.branch.clone()])
        .await
        .unwrap();
    assert!(r.clean, "{r:?}");
    // the source repository got the two branches and nothing else
    assert_eq!(sh(&e.home, &e.repo, &["status", "--porcelain"]), "");
}

#[tokio::test]
async fn a_runs_tasks_made_at_once_share_one_store() {
    // the runner starts a run's ready tasks together: the first ones each cloned the store, and all but one failed
    let e = env();
    let (h, _) = shared(&e, TreeMode::Snapshot, Policy::default(), None);
    let b = base(&e);
    let (t1, t2, t3) = tokio::join!(
        h.task_worktree(&e.repo, "r1", "1", &b),
        h.task_worktree(&e.repo, "r1", "2", &b),
        h.task_worktree(&e.repo, "r1", "3", &b),
    );
    for t in [t1, t2, t3] {
        let t = t.unwrap();
        assert!(t.path.join("x.txt").is_file(), "{t:?}");
    }
}

#[tokio::test]
async fn a_rebuilt_snapshot_trees_base_is_read_against_the_repository_now() {
    let e = env();
    sh(&e.home, &e.repo, &["branch", "integ", "HEAD"]);
    let (h, _) = shared(&e, TreeMode::Snapshot, Policy::default(), None);
    let w = h
        .task_worktree(&e.repo, "m1", "w1", &base(&e))
        .await
        .unwrap();
    commit(&e, &w, "a.txt", "A\n");
    let tip = sh(&e.home, &w.path, &["rev-parse", "HEAD"])
        .trim()
        .to_owned();
    // the manager merged the worker: the repository's integration branch is at the worker's tip
    h.import(&e.repo, &w).await.unwrap();
    sh(&e.home, &e.repo, &["branch", "-f", "integ", &w.branch]);
    // the tree's own copy of the integration branch is where it was: a merge-base read there is stale
    let stale = super::super::tick::git(&w.path, &["merge-base", &w.branch, "integ"])
        .await
        .unwrap();
    assert_eq!(stale, base(&e));
    let got = h
        .rebuilt_base(&e.repo, &w.path, &w.branch, "integ")
        .await
        .unwrap();
    assert_eq!(got, tip);
    assert_eq!(sh(&e.home, &e.repo, &["status", "--porcelain"]), "");
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

#[test]
fn hunks_give_the_lines_a_diff_touches() {
    let text = "diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -2 +2,2 @@\n-two\n+2\n+2b\n\
                @@ -9,2 +10,0 @@\n--- not a header\n-a\n-b\n\
                diff --git a/gone.rs b/gone.rs\n--- a/gone.rs\n+++ /dev/null\n@@ -1,3 +0,0 @@\n-a\n-b\n-c\n";
    let r = parse_ranges(text);
    assert_eq!(r["x.txt"], vec![(2, 4), (9, 11)]);
    assert_eq!(r["gone.rs"], vec![(1, 4)]);
}

#[tokio::test]
async fn two_tasks_in_review_on_one_file_clash_with_their_lines() {
    use crate::runner::clash::{self, Rule};
    let e = env();
    let h = hub(&e, TreeMode::Worktree, Policy::default(), None);
    let b = base(&e);
    let t1 = h.task_worktree(&e.repo, "r1", "t1", &b).await.unwrap();
    let t2 = h.task_worktree(&e.repo, "r1", "t2", &b).await.unwrap();
    commit(&e, &t1, "x.txt", "one\n2 by t1\nthree\n");
    commit(&e, &t2, "x.txt", "one\n2 by t2\nthree\nfour\n");
    let d1 = h.diffs(&e.repo, &t1).await.unwrap();
    let d2 = h.diffs(&e.repo, &t2).await.unwrap();
    assert_eq!(d1["x.txt"].ranges, vec![(2, 3)]);
    assert_eq!(d2["x.txt"].ranges, vec![(2, 3), (4, 5)]);
    let task = |id: &str, n: i64| clash::RunTask {
        id: id.into(),
        n,
        status: "in-review".into(),
        agent: None,
        head: Some(format!("h{n}")),
    };
    let run = clash::RunState {
        status: "running".into(),
        tasks: vec![task("t1", 1), task("t2", 2)],
        sessions: vec![],
        carded: Default::default(),
        settled_subjects: Default::default(),
        open_clash_tasks: Default::default(),
    };
    let mut index = clash::DiffIndex::new();
    index.insert("t1".into(), d1);
    index.insert("t2".into(), d2);
    let found = clash::scan(&run, &[], &index);
    assert!(
        found.iter().any(|c| c.rule == Rule::Overlap
            && c.key == "overlap:1:2"
            && c.files == vec!["x.txt".to_string()]),
        "{found:?}"
    );
}

#[tokio::test]
async fn a_ci_card_answered_yes_clears_and_merges_and_unanswered_does_not() {
    let e = env();
    let dbdir = tempfile::tempdir().unwrap();
    let db = CoordDb::spawn(dbdir.path().join("work.db"));
    let (h, p) = shared(
        &e,
        TreeMode::Worktree,
        Policy {
            ci: Some((db, MatrixGate::default())),
            ..Policy::default()
        },
        None,
    );
    let b = base(&e);
    let yes = h.task_worktree(&e.repo, "r1", "t1", &b).await.unwrap();
    commit(&e, &yes, ".github/workflows/ci.yml", "on: push\n");
    accept_all(&h, &e, &yes, &p.marks).await;
    assert!(matches!(
        h.merge_gate(&e.repo, &yes).await.unwrap(),
        Gate::Ask(_)
    ));
    // the card is still open: nothing merges
    let r = RunGit::merge_into(&h, &e.repo, &yes).await.unwrap_err();
    assert!(r.stderr.contains("not cleared"), "{r:?}");
    assert!(!e.repo.join(".github/workflows/ci.yml").exists());
    // answered yes: the branch is cleared and exactly that tip merges
    RunGit::clear_gate(&h, &yes.branch);
    assert_eq!(
        RunGit::merge_into(&h, &e.repo, &yes).await.unwrap(),
        MergeOutcome::Merged
    );
    assert!(e.repo.join(".github/workflows/ci.yml").exists());
    // another task whose card is answered no (never cleared) does not merge, however often it is tried
    let no = h.task_worktree(&e.repo, "r1", "t2", &b).await.unwrap();
    commit(&e, &no, "Makefile", "all:\n");
    accept_all(&h, &e, &no, &p.marks).await;
    assert!(matches!(
        h.merge_gate(&e.repo, &no).await.unwrap(),
        Gate::Ask(_)
    ));
    for _ in 0..2 {
        assert!(RunGit::merge_into(&h, &e.repo, &no).await.is_err());
    }
    assert!(!e.repo.join("Makefile").exists());
}

#[tokio::test]
async fn prepare_writes_a_snapshot_tasks_bundle_and_only_that() {
    let e = env();
    let h = hub(&e, TreeMode::Snapshot, Policy::default(), None);
    let b = base(&e);
    let t = h.task_worktree(&e.repo, "r1", "t1", &b).await.unwrap();
    commit(&e, &t, "src/a.rs", "fn a() {}\n");
    let bundle = HubGit::bundle_path(&t);
    assert!(bundle.to_string_lossy().ends_with("1.bundle"), "{bundle:?}");
    assert!(!bundle.exists());
    RunGit::prepare(&h, &t).await.unwrap();
    assert!(bundle.exists());
    // the trusted repository verifies it: its prerequisite is there
    sh(
        &e.home,
        &e.repo,
        &["bundle", "verify", "-q", &bundle.to_string_lossy()],
    );
    // a worktree-mode task has no bundle
    let h2 = hub(&e, TreeMode::Worktree, Policy::default(), None);
    let w = h2.task_worktree(&e.repo, "r2", "t1", &b).await.unwrap();
    RunGit::prepare(&h2, &w).await.unwrap();
    assert!(!HubGit::bundle_path(&w).exists());
}

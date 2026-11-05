use super::*;
use crate::runner::git::{GatePolicy, HubGit};
use crate::runner::{GitError, GitFuture, RunGit, TaskTree, TreeMode};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

struct Env {
    _dir: tempfile::TempDir,
    home: PathBuf,
    repo: PathBuf,
    trees: PathBuf,
    snaps: PathBuf,
}

fn sh(env: &Path, dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
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
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// A repository on `main` with one commit.
fn env() -> Env {
    let dir = tempfile::tempdir().unwrap();
    let base = std::fs::canonicalize(dir.path()).unwrap();
    let (home, repo) = (base.join("home"), base.join("repo"));
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&repo).unwrap();
    sh(&home, &repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("a.txt"), "one\n").unwrap();
    sh(&home, &repo, &["add", "-A"]);
    sh(&home, &repo, &["commit", "-q", "-m", "base"]);
    Env {
        _dir: dir,
        home,
        trees: base.join("trees"),
        snaps: base.join("cp"),
        repo,
    }
}

struct NoPolicy;
impl GatePolicy for NoPolicy {
    fn accepted<'a>(&'a self, _: &'a TaskTree) -> GitFuture<'a, BTreeMap<String, String>> {
        Box::pin(async { Ok(BTreeMap::new()) })
    }
    fn ci_config<'a>(
        &'a self,
        _: &'a TaskTree,
        _: runstav::methods::matrix::Facts,
    ) -> GitFuture<'a, crate::matrix_gate::Gate> {
        Box::pin(async {
            Err(GitError {
                what: "test".into(),
                stderr: "no matrix".into(),
            })
        })
    }
}

type Rows = Arc<Mutex<Vec<WorktreeBase>>>;

fn hub(e: &Env, mode: TreeMode) -> (HubGit, Rows) {
    let rows: Rows = Arc::default();
    let sink = rows.clone();
    let h = HubGit::new(e.trees.clone(), mode, Box::new(NoPolicy), None)
        .with_env(vec![("HOME".into(), e.home.to_string_lossy().into_owned())])
        .with_bases(
            e.snaps.clone(),
            Arc::new(move |r| sink.lock().unwrap().push(r)),
        );
    (h, rows)
}

fn listing(snaps: &Path, wt: &Path, tree: &str) -> Vec<String> {
    let shadow = snapshot::repo_of(snaps, wt);
    let out = Command::new("git")
        .env("GIT_DIR", shadow)
        .args(["ls-tree", "-r", "--name-only", tree])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_string)
        .collect()
}

/// Pattern D (real git and files, no clock): both tree modes record the base when they make the tree.
#[tokio::test]
async fn recorded_at_creation_with_its_tree() {
    for mode in [TreeMode::Worktree, TreeMode::Snapshot] {
        let e = env();
        let head = sh(&e.home, &e.repo, &["rev-parse", "HEAD"]);
        let (h, rows) = hub(&e, mode);
        let tree = h.task_worktree(&e.repo, "run1", "1", "main").await.unwrap();
        let rows = rows.lock().unwrap();
        assert_eq!(rows.len(), 1, "{mode:?}");
        let r = &rows[0];
        assert_eq!(r.worktree, tree.path.to_string_lossy());
        assert_eq!(r.repo, e.repo.to_string_lossy());
        assert_eq!(r.base_commit.as_deref(), Some(head.as_str()));
        let t = r.base_tree.as_deref().expect("a base tree");
        assert_eq!(listing(&e.snaps, &tree.path, t), ["a.txt"]);
    }
}

/// Pattern D: the branch is the one the tree was cut from, never `main` because it is the default.
#[tokio::test]
async fn never_main_by_default() {
    let e = env();
    sh(&e.home, &e.repo, &["checkout", "-q", "-b", "rp-i6"]);
    std::fs::write(e.repo.join("b.txt"), "two\n").unwrap();
    sh(&e.home, &e.repo, &["add", "-A"]);
    sh(&e.home, &e.repo, &["commit", "-q", "-m", "second"]);
    let tip = sh(&e.home, &e.repo, &["rev-parse", "HEAD"]);
    sh(&e.home, &e.repo, &["checkout", "-q", "main"]);
    let (h, rows) = hub(&e, TreeMode::Worktree);
    // named by its commit: the one branch that points there
    h.task_worktree(&e.repo, "run1", "1", &tip).await.unwrap();
    // named by its branch, with the repository on main (the tree above now points there too)
    h.task_worktree(&e.repo, "run1", "2", "rp-i6")
        .await
        .unwrap();
    let main_tip = sh(&e.home, &e.repo, &["rev-parse", "main"]);
    // a commit two branches point at: not guessed
    sh(&e.home, &e.repo, &["branch", "twin", "main"]);
    h.task_worktree(&e.repo, "run1", "3", &main_tip)
        .await
        .unwrap();
    // a plan run's own branch, at the same commit as main: the tree `job/run2-1` was cut from `job/run2`
    sh(&e.home, &e.repo, &["branch", "job/run2", "main"]);
    h.task_worktree(&e.repo, "run2", "1", &main_tip)
        .await
        .unwrap();
    let got: Vec<Option<String>> = rows
        .lock()
        .unwrap()
        .iter()
        .map(|r| r.base_branch.clone())
        .collect();
    assert_eq!(
        got,
        [
            Some("rp-i6".into()),
            Some("rp-i6".into()),
            None,
            Some("job/run2".into())
        ]
    );
}

/// Pattern D.
#[test]
fn docs_agent_measures_from_the_org_head() {
    let e = env();
    let head = sh(&e.home, &e.repo, &["rev-parse", "HEAD"]);
    // a docs agent works in the folder itself, here a subfolder of the repository
    std::fs::create_dir_all(e.repo.join("docs")).unwrap();
    let cwd = e.repo.join("docs");
    let r = session_base(&e.snaps, &cwd, "s1").expect("inside a repository");
    assert_eq!(r.repo, e.repo.to_string_lossy());
    assert_eq!(r.base_commit.as_deref(), Some(head.as_str()));
    assert_eq!(r.base_branch.as_deref(), Some("main"));
    assert_eq!(r.worktree, cwd.to_string_lossy());
    assert!(r.base_tree.is_some());
    // not a repository: no base
    let plain = tempfile::tempdir().unwrap();
    assert!(session_base(&e.snaps, plain.path(), "s2").is_none());
}

fn base_row(repo: &str, wt: &str, branch: Option<&str>) -> WorktreeBase {
    WorktreeBase {
        worktree: wt.into(),
        repo: repo.into(),
        base_branch: branch.map(str::to_string),
        base_commit: None,
        base_tree: None,
        at: 1.0,
    }
}

/// Pattern D.
#[test]
fn ancestry_across_two_repos() {
    let roots = [PathBuf::from("/w/org"), PathBuf::from("/w/org/drgnx")];
    let rows = [
        base_row("/w/org", "/s/hub/runs/runA/1", Some("main")),
        base_row("/w/org/drgnx", "/s/hub/runs/runB/2", Some("job/runB-1")),
        // a chain: runB's task 3 is based on runB's task 2
        base_row("/w/org/drgnx", "/s/hub/runs/runB/3", Some("job/runB-2")),
        // no base branch, a session's own folder, and another workspace
        base_row("/w/org", "/s/hub/runs/runC/1", None),
        base_row("/w/org", "/w/org", Some("main")),
        base_row("/w/other", "/s/hub/runs/runD/1", Some("main")),
    ];
    let b = |repo: &str, branch: &str| BranchRef {
        repo: repo.into(),
        branch: branch.into(),
    };
    assert_eq!(
        ancestry_of(&rows, &roots),
        [
            (b("/w/org", "job/runA-1"), b("/w/org", "main")),
            (
                b("/w/org/drgnx", "job/runB-2"),
                b("/w/org/drgnx", "job/runB-1")
            ),
            (
                b("/w/org/drgnx", "job/runB-3"),
                b("/w/org/drgnx", "job/runB-2")
            ),
        ]
    );
}

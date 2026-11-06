//! Writing into an agent's tree.  Pattern D throughout: temp trees, the shadow repository and a temp store; no hub
//! process and no sandbox (the sandboxed commit's tests are the sandbox lane's, in `sandboxed.rs`).

use super::*;
use crate::agents::lock::NEVER_RESTORED;
use crate::timeline::snapshot::{self, Restored};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::Path;

fn sh(dir: &Path, args: &[&str]) -> String {
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
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {out:?}");
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A temp folder with a checkpoint root `cp` and a worktree `wt`.
fn trees() -> (tempfile::TempDir, PathBuf, PathBuf) {
    let d = tempfile::tempdir().unwrap();
    let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
    std::fs::create_dir_all(&wt).unwrap();
    (d, root, wt)
}

fn mode(p: &Path) -> u32 {
    std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o777
}

/// WT made equal to the checkpoint TO, every path.
fn restore(root: &Path, wt: &Path, to: &str) -> Restored {
    snapshot::restore_into(root, wt, wt, to, None, &[]).unwrap()
}

#[test]
fn restore_keeps_the_executable_bit() {
    let (_d, root, wt) = trees();
    std::fs::write(wt.join("run.sh"), "v1").unwrap();
    std::fs::set_permissions(wt.join("run.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let cp = snapshot::take(&root, &wt, "s1", 1, &[]).unwrap();
    std::fs::write(wt.join("run.sh"), "v2").unwrap();
    std::fs::set_permissions(wt.join("run.sh"), std::fs::Permissions::from_mode(0o644)).unwrap();
    let r = restore(&root, &wt, &cp);
    assert_eq!(std::fs::read_to_string(wt.join("run.sh")).unwrap(), "v1");
    assert_eq!(mode(&wt.join("run.sh")), 0o755);
    assert_eq!(r.written, [PathBuf::from("run.sh")]);
}

#[test]
fn restore_never_writes_protected_paths() {
    let (_d, root, wt) = trees();
    std::fs::create_dir_all(wt.join(".claude")).unwrap();
    std::fs::write(wt.join(".claude/settings.json"), "{}").unwrap();
    std::fs::write(wt.join(".envrc"), "export A=1").unwrap();
    std::fs::write(wt.join("a.txt"), "one").unwrap();
    let cp = snapshot::take(&root, &wt, "s1", 1, &[]).unwrap();
    std::fs::write(wt.join(".claude/settings.json"), "{\"allow\": true}").unwrap();
    std::fs::write(wt.join(".envrc"), "export A=2").unwrap();
    std::fs::write(wt.join("a.txt"), "two").unwrap();
    let r = restore(&root, &wt, &cp);
    assert_eq!(std::fs::read_to_string(wt.join("a.txt")).unwrap(), "one");
    // the agent's later settings stay as they are: the card lists them
    assert_eq!(
        std::fs::read_to_string(wt.join(".claude/settings.json")).unwrap(),
        "{\"allow\": true}"
    );
    assert_eq!(
        std::fs::read_to_string(wt.join(".envrc")).unwrap(),
        "export A=2"
    );
    let mut skipped: Vec<&Path> = r.skipped.iter().map(|(p, _)| p.as_path()).collect();
    skipped.sort();
    assert_eq!(
        skipped,
        [Path::new(".claude/settings.json"), Path::new(".envrc")]
    );
    assert_eq!(r.written, [PathBuf::from("a.txt")]);
}

#[test]
fn restorable_refuses_every_git_component() {
    for p in [
        ".git/hooks/x",
        ".git/config",
        ".git/config.worktree",
        "sub/.git/config",
        ".git",
    ] {
        assert!(!restorable(Path::new(p), &[]), "{p}");
    }
    for p in ["src/a.rs", "git/config", ".gitignore", "a/.github/ci.yml"] {
        assert!(restorable(Path::new(p), &[]), "{p}");
    }
}

#[test]
fn restorable_is_the_runners_list() {
    for e in NEVER_RESTORED {
        for p in [e.to_string(), format!("sub/{e}"), format!("{e}/x")] {
            let p = Path::new(&p);
            assert_eq!(
                restorable(p, &[]),
                crate::runners::returned::protected(p).is_none(),
                "{}",
                p.display()
            );
            assert!(!restorable(p, &[]), "{}", p.display());
        }
    }
}

#[test]
fn secret_patterns_are_skipped() {
    for p in [
        "id_rsa",
        "deploy/id_ed25519",
        "x/server.pem",
        "secrets.env",
        "k/tls.key",
    ] {
        assert!(!restorable(Path::new(p), &[]), "{p}");
    }
    // an extra pattern from the settings, as the snapshot took it
    let extra = ["config/local.toml".to_string()];
    assert!(restorable(Path::new("config/local.toml"), &[]));
    assert!(!restorable(Path::new("config/local.toml"), &extra));
    assert!(restorable(Path::new("config/other.toml"), &extra));
}

#[test]
fn restore_keeps_a_link_as_a_link() {
    let (d, root, wt) = trees();
    let outside = d.path().join("outside");
    std::fs::write(&outside, "keep").unwrap();
    symlink("target-a", wt.join("l")).unwrap();
    let cp = snapshot::take(&root, &wt, "s1", 1, &[]).unwrap();
    // the agent planted a link to a file outside its tree in its place
    std::fs::remove_file(wt.join("l")).unwrap();
    symlink(&outside, wt.join("l")).unwrap();
    let r = restore(&root, &wt, &cp);
    assert_eq!(
        std::fs::read_link(wt.join("l")).unwrap(),
        Path::new("target-a")
    );
    assert_eq!(std::fs::read_to_string(&outside).unwrap(), "keep");
    assert_eq!(r.written, [PathBuf::from("l")]);
}

#[test]
fn gitlink_is_skipped_and_listed() {
    let (_d, root, wt) = trees();
    std::fs::write(wt.join("a.txt"), "one").unwrap();
    let base = snapshot::take(&root, &wt, "s1", 1, &[]).unwrap();
    // a checkpoint holding a submodule: written by hand into the shadow repository
    let repo = snapshot::repo_of(&root, &wt);
    let idx = repo.join("index-gitlink");
    let git = |args: &[&str]| {
        let out = std::process::Command::new("git")
            .args(args)
            .env("GIT_DIR", &repo)
            .env("GIT_INDEX_FILE", &idx)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {out:?}");
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    };
    git(&["read-tree", &base]);
    git(&[
        "update-index",
        "--add",
        "--cacheinfo",
        "160000,0123456789abcdef0123456789abcdef01234567,sub",
    ]);
    let cp = git(&["write-tree"]);
    let r = restore(&root, &wt, &cp);
    assert!(std::fs::symlink_metadata(wt.join("sub")).is_err());
    assert_eq!(r.skipped, [(PathBuf::from("sub"), "gitlink".to_string())]);
    assert!(r.written.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn commit_nothing_is_none() {
    let (d, _root, wt) = trees();
    let f = crate::runner::graph_plan_tests::front(d.path());
    sh(&wt, &["init", "-q", "-b", "main"]);
    std::fs::write(wt.join("a.txt"), "one").unwrap();
    sh(&wt, &["add", "a.txt"]);
    sh(&wt, &["commit", "-q", "-m", "base"]);
    let paths = [PathBuf::from("a.txt")];
    // an untouched folder of a session with no sandbox: plain git, and nothing to commit is quiet
    assert_eq!(
        commit_in_sandbox(&f, "s1", &wt, &paths, "revert").await,
        Ok(None)
    );
    std::fs::write(wt.join("a.txt"), "two").unwrap();
    std::fs::write(wt.join("b.txt"), "new").unwrap();
    let paths = [PathBuf::from("a.txt"), PathBuf::from("b.txt")];
    let made = commit_in_sandbox(&f, "s1", &wt, &paths, "revert")
        .await
        .unwrap();
    assert_eq!(made, snapshot::head_of(&wt));
    assert!(made.is_some());
    assert_eq!(sh(&wt, &["log", "-1", "--format=%s"]), "revert");
    // again after a crash: quiet
    assert_eq!(
        commit_in_sandbox(&f, "s1", &wt, &paths, "revert").await,
        Ok(None)
    );
}

/// The commit takes only its paths: a file the agent staged besides them stays staged and out of the commit, and a
/// path neither HEAD nor the tree has (a file the revert removed that was never added) is no error.
#[tokio::test(flavor = "multi_thread")]
async fn commit_takes_only_its_paths() {
    let (d, _root, wt) = trees();
    let f = crate::runner::graph_plan_tests::front(d.path());
    sh(&wt, &["init", "-q", "-b", "main"]);
    std::fs::write(wt.join("a.txt"), "one").unwrap();
    sh(&wt, &["add", "a.txt"]);
    sh(&wt, &["commit", "-q", "-m", "base"]);
    std::fs::write(wt.join("other.txt"), "staged").unwrap();
    sh(&wt, &["add", "other.txt"]);
    std::fs::write(wt.join("a.txt"), "two").unwrap();
    let paths = [PathBuf::from("a.txt"), PathBuf::from("never-added.txt")];
    let made = commit_in_sandbox(&f, "s1", &wt, &paths, "revert")
        .await
        .unwrap();
    assert!(made.is_some());
    assert_eq!(
        sh(&wt, &["show", "--name-only", "--format=", "HEAD"]),
        "a.txt"
    );
    assert_eq!(sh(&wt, &["diff", "--cached", "--name-only"]), "other.txt");
    assert_eq!(sh(&wt, &["diff", "--name-only"]), "");
    assert!(!wt.join(".git").join(COMMIT_INDEX).exists());
}

/// A source session S1 in its own repository WT with steps 1 and 2: step 2's checkpoint (`a.txt` "two", `new.txt`,
/// `gone.txt` removed) and the commit HEAD at both.  With BOGUS_HEAD the steps record a head the repository does not
/// have, and the worktree's base row names HEAD instead.
async fn source(f: &Front, root: &Path, wt: &Path, bogus_head: bool) -> (String, String) {
    sh(wt, &["init", "-q", "-b", "main"]);
    std::fs::write(wt.join("a.txt"), "one").unwrap();
    std::fs::write(wt.join("gone.txt"), "x").unwrap();
    sh(wt, &["add", "-A"]);
    sh(wt, &["commit", "-q", "-m", "base"]);
    let head = sh(wt, &["rev-parse", "HEAD"]);
    std::fs::write(wt.join("a.txt"), "two").unwrap();
    std::fs::write(wt.join("new.txt"), "n").unwrap();
    std::fs::remove_file(wt.join("gone.txt")).unwrap();
    let cp = snapshot::take(root, wt, "s1", 2, &[]).unwrap();
    let recorded = if bogus_head {
        "0123456789abcdef0123456789abcdef01234567".to_string()
    } else {
        head.clone()
    };
    let (cwd, h, c, real) = (
        wt.to_string_lossy().into_owned(),
        recorded,
        cp.clone(),
        head.clone(),
    );
    f.writer
        .db
        .write(
            // the hub's own author: a worktree base is the hub's
            urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "test"),
            move |tx| {
                let project = tx.meta().project;
                urdr::graph::entity::create(
                    tx,
                    urdr::graph::entity::EntityNew {
                        id: "session:s1".into(),
                        kind: "session".into(),
                        project,
                        title: None,
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data: serde_json::json!({"profile": "mock", "cwd": cwd, "role": "worker"}),
                        origin: urdr::graph::entity::Origin::Recorded,
                        source: None,
                    },
                )?;
                tx.sql().execute(
                    "insert into step (session, seq, class, start, snapshot, head) values \
                     ('session:s1', 1, 'tool', 1.0, null, ?1), ('session:s1', 2, 'tool', 2.0, ?2, ?1)",
                    (&h, &c),
                )?;
                if bogus_head {
                    norn::write::work::put_base(
                        tx,
                        norn::write::work::WorktreeBase {
                            worktree: cwd.clone(),
                            repo: cwd.clone(),
                            base_branch: Some("main".into()),
                            base_commit: Some(real),
                            base_tree: None,
                            at: 1.0,
                        },
                    )?;
                }
                Ok(())
            },
        )
        .await
        .unwrap();
    (head, cp)
}

/// A front with its store's folders set, so the checkpoints live under `hub/checkpoints`.
fn front_with_dirs(d: &Path) -> (Front, PathBuf) {
    let f = crate::runner::graph_plan_tests::front(d);
    for s in ["home", "config", "hub"] {
        std::fs::create_dir_all(d.join(s)).unwrap();
    }
    let _ = f.dirs.set(crate::graph::StoreDirs {
        home: d.join("home"),
        config: d.join("config"),
        hub: d.join("hub"),
    });
    (f, d.join("hub").join("checkpoints"))
}

fn listing(dir: &Path) -> Vec<(String, String)> {
    let mut v: Vec<(String, String)> = std::fs::read_dir(dir)
        .unwrap()
        .flatten()
        .filter(|e| e.file_name() != ".git")
        .map(|e| {
            (
                e.file_name().to_string_lossy().into_owned(),
                std::fs::read_to_string(e.path()).unwrap_or_default(),
            )
        })
        .collect();
    v.sort();
    v
}

#[tokio::test(flavor = "multi_thread")]
async fn fork_tree_equals_the_checkpoint() {
    let d = tempfile::tempdir().unwrap();
    let (f, root) = front_with_dirs(d.path());
    let wt = d.path().join("wt");
    std::fs::create_dir_all(&wt).unwrap();
    let (head, _cp) = source(&f, &root, &wt, false).await;
    let t = Target {
        sid: "s1".into(),
        seq: 2,
    };
    let tree = fork_tree(&f, &t, "s9abcdef12").await.unwrap();
    assert_eq!(tree.base, head);
    assert_eq!(
        listing(&tree.path),
        [
            ("a.txt".into(), "two".into()),
            ("new.txt".into(), "n".into())
        ]
    );
    // the source is left as it is
    assert_eq!(std::fs::read_to_string(wt.join("a.txt")).unwrap(), "two");
}

/// The gate a fork never asks.
struct NoGate;

impl crate::runner::git::GatePolicy for NoGate {
    fn accepted<'a>(
        &'a self,
        _: &'a TaskTree,
    ) -> crate::runner::GitFuture<'a, std::collections::BTreeMap<String, String>> {
        Box::pin(async { Ok(Default::default()) })
    }
    fn ci_config<'a>(
        &'a self,
        _: &'a TaskTree,
        _: runstav::methods::matrix::Facts,
    ) -> crate::runner::GitFuture<'a, crate::matrix_gate::Gate> {
        Box::pin(async {
            Err(crate::runner::GitError {
                what: "gate".into(),
                stderr: "no gate here".into(),
            })
        })
    }
}

/// A snapshot task's step head is a commit only its own folder has: the fork brings the task's branch into the
/// trusted repository through its bundle first (verified, fsck'd), so the fork starts at that commit, not at the
/// task's base.
#[tokio::test(flavor = "multi_thread")]
async fn fork_of_a_snapshot_task_imports_through_the_bundle() {
    let d = tempfile::tempdir().unwrap();
    let (f, root) = front_with_dirs(d.path());
    let repo = d.path().join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    sh(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("a.txt"), "one").unwrap();
    sh(&repo, &["add", "-A"]);
    sh(&repo, &["commit", "-q", "-m", "base"]);
    let base = sh(&repo, &["rev-parse", "HEAD"]);
    let git = crate::runner::git::HubGit::new(
        d.path().join("runs"),
        crate::runner::TreeMode::Snapshot,
        Box::new(NoGate),
        None,
    )
    .with_env(vec![
        ("GIT_CONFIG_GLOBAL".into(), "/dev/null".into()),
        ("GIT_AUTHOR_NAME".into(), "t".into()),
        ("GIT_AUTHOR_EMAIL".into(), "t@t".into()),
        ("GIT_COMMITTER_NAME".into(), "t".into()),
        ("GIT_COMMITTER_EMAIL".into(), "t@t".into()),
    ]);
    let src = crate::runner::RunGit::task_worktree(&git, &repo, "r1", "s1", &base)
        .await
        .unwrap();
    f.core.runs.set_git(std::sync::Arc::new(git));
    // the agent's commit in its snapshot folder: the trusted repository does not have it
    std::fs::write(src.path.join("a.txt"), "two").unwrap();
    sh(&src.path, &["add", "-A"]);
    sh(&src.path, &["commit", "-q", "-m", "agent"]);
    let head = sh(&src.path, &["rev-parse", "HEAD"]);
    assert!(
        std::process::Command::new("git")
            .args(["cat-file", "-e", &format!("{head}^{{commit}}")])
            .current_dir(&repo)
            .status()
            .is_ok_and(|s| !s.success())
    );
    let cp = snapshot::take(&root, &src.path, "s1", 2, &[]).unwrap();
    let (cwd, h, c, r, b) = (
        src.path.to_string_lossy().into_owned(),
        head.clone(),
        cp,
        repo.to_string_lossy().into_owned(),
        base.clone(),
    );
    f.writer
        .db
        .write(
            urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "test"),
            move |tx| {
                let project = tx.meta().project;
                urdr::graph::entity::create(
                    tx,
                    urdr::graph::entity::EntityNew {
                        id: "session:s1".into(),
                        kind: "session".into(),
                        project,
                        title: None,
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data: serde_json::json!({"profile": "mock", "cwd": cwd, "role": "worker"}),
                        origin: urdr::graph::entity::Origin::Recorded,
                        source: None,
                    },
                )?;
                tx.sql().execute(
                    "insert into step (session, seq, class, start, snapshot, head) values \
                     ('session:s1', 2, 'tool', 2.0, ?1, ?2)",
                    (&c, &h),
                )?;
                norn::write::work::put_base(
                    tx,
                    norn::write::work::WorktreeBase {
                        worktree: cwd.clone(),
                        repo: r,
                        base_branch: Some("main".into()),
                        base_commit: Some(b),
                        base_tree: None,
                        at: 1.0,
                    },
                )?;
                Ok(())
            },
        )
        .await
        .unwrap();
    let t = Target {
        sid: "s1".into(),
        seq: 2,
    };
    let tree = fork_tree(&f, &t, "s9abcdef12").await.unwrap();
    assert_eq!(tree.base, head, "the fork starts at the task's own commit");
    assert_eq!(listing(&tree.path), [("a.txt".into(), "two".into())]);
}

#[tokio::test(flavor = "multi_thread")]
async fn fork_tree_falls_back_to_the_worktree_base() {
    let d = tempfile::tempdir().unwrap();
    let (f, root) = front_with_dirs(d.path());
    let wt = d.path().join("wt");
    std::fs::create_dir_all(&wt).unwrap();
    // the step's recorded head does not verify in the repository: the worktree's recorded base is the fork's
    let (head, _cp) = source(&f, &root, &wt, true).await;
    let t = Target {
        sid: "s1".into(),
        seq: 2,
    };
    let tree = fork_tree(&f, &t, "s9abcdef12").await.unwrap();
    assert_eq!(tree.base, head);
    assert_eq!(
        listing(&tree.path),
        [
            ("a.txt".into(), "two".into()),
            ("new.txt".into(), "n".into())
        ]
    );
}

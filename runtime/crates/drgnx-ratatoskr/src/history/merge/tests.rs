//! A task's branch merged into the job's tree, recorded onto a real `history.db` in a real git repository (pattern D:
//! temporary folders, git, no process of the hub, every time a parameter).

use super::super::wire::{Hubs, git_dirs};
use super::super::{Hub, Tree};
use std::path::{Path, PathBuf};
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
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn ok(dir: &Path, args: &[&str]) -> String {
    let st = std::process::Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
    git(dir, &["rev-parse", "HEAD"])
}

const BASE: &str = "l1\nl2\nl3\nl4\nl5\n";

/// The job's tree (the repository's main worktree, `a.txt` committed) and a task's linked worktree on branch `t`.
struct Fx {
    _d: tempfile::TempDir,
    main: PathBuf,
    task: PathBuf,
    hist: tempfile::TempDir,
}

impl Fx {
    fn new() -> Fx {
        let d = tempfile::tempdir().unwrap();
        let (main, task) = (d.path().join("main"), d.path().join("task"));
        std::fs::create_dir_all(&main).unwrap();
        git(&main, &["init", "-q", "-b", "main"]);
        std::fs::write(main.join("a.txt"), BASE).unwrap();
        ok(&main, &["add", "a.txt"]);
        ok(&main, &["commit", "-q", "-m", "base"]);
        ok(
            &main,
            &["worktree", "add", "-q", "-b", "t", task.to_str().unwrap()],
        );
        Fx {
            _d: d,
            main,
            task,
            hist: tempfile::tempdir().unwrap(),
        }
    }

    fn tree(p: &Path) -> Tree {
        let (gd, _) = git_dirs(p).unwrap();
        Tree::new(p, &gd, Some(&git(p, &["rev-parse", "HEAD"])))
    }

    /// The agent's write of TEXT to `a.txt` in the task's tree, recorded as the session handler records it, then
    /// committed there.
    fn agent_writes(&self, hub: &Hub, text: &str) {
        let cause = Cause {
            session: Some("s1".into()),
            ..Cause::default()
        };
        let v = hub
            .on_agent_write(
                &Fx::tree(&self.task),
                "a.txt",
                text.as_bytes(),
                "s1",
                cause,
                10.0,
            )
            .unwrap();
        assert!(!v.is_empty());
        std::fs::write(self.task.join("a.txt"), text).unwrap();
        ok(&self.task, &["commit", "-q", "-am", "agent"]);
    }
}

fn merge_record(hub: &Hub, op: OpId) -> verdandi::OpRecord {
    let r = hub.with(|h| h.op(op).unwrap());
    assert_eq!(r.kind, Kind::Merge);
    r
}

/// A clean merge: the job's document is the union, the agent's characters with their own element ids (compare finds
/// no hunk between the two branches), and no correction.
#[test]
fn clean_merge_keeps_the_agents_element_ids() {
    let f = Fx::new();
    let hub = Hub::open(f.hist.path()).unwrap();
    f.agent_writes(&hub, &BASE.replace("l2", "agent"));
    let old = git(&f.main, &["rev-parse", "HEAD"]);
    let new = ok(&f.main, &["merge", "-q", "--no-ff", "-m", "merge t", "t"]);
    let (main, task) = (Fx::tree(&f.main), Fx::tree(&f.task));
    let op = hub
        .on_git_merge(&main, Some(&task), &old, &new, 20.0)
        .unwrap()
        .expect("a merge record");
    let r = merge_record(&hub, op);
    assert!(r.spans.is_empty(), "no correction: {r:?}");
    assert_eq!(
        hub.text(&main, "a.txt").unwrap().as_deref(),
        Some(BASE.replace("l2", "agent").as_str())
    );
    let diffs = hub.with(|h| {
        let to = h.find_branch(&main.branch_name()).unwrap().unwrap();
        let from = h.find_branch(&task.branch_name()).unwrap().unwrap();
        h.compare(to, from).unwrap()
    });
    assert!(
        diffs.iter().all(|d| d.hunks.is_empty()),
        "the same elements on both branches: {diffs:?}"
    );
    // the git event adds nothing the union does not hold
    let externals = hub.with(|h| {
        (1..=h.count("op").unwrap())
            .filter(|i| h.op(OpId(*i)).unwrap().kind == Kind::External)
            .count()
    });
    assert_eq!(externals, 0);
}

/// A conflict the user resolved: the union is not git's text, so one correction by the merge's author makes it so.
#[test]
fn a_resolved_conflict_is_one_correction() {
    let f = Fx::new();
    let hub = Hub::open(f.hist.path()).unwrap();
    f.agent_writes(&hub, &BASE.replace("l3", "agent"));
    std::fs::write(f.main.join("a.txt"), BASE.replace("l3", "mine")).unwrap();
    let old = ok(&f.main, &["commit", "-q", "-am", "mine"]);
    git(&f.main, &["merge", "-q", "--no-ff", "-m", "merge t", "t"]);
    let resolved = BASE.replace("l3", "both");
    std::fs::write(f.main.join("a.txt"), &resolved).unwrap();
    ok(&f.main, &["add", "a.txt"]);
    let new = ok(&f.main, &["commit", "-q", "--no-edit"]);
    let (main, task) = (Fx::tree(&f.main), Fx::tree(&f.task));
    let op = hub
        .on_git_merge(&main, Some(&task), &old, &new, 20.0)
        .unwrap()
        .expect("a merge record");
    let r = merge_record(&hub, op);
    assert!(!r.spans.is_empty(), "one correction: {r:?}");
    assert!(r.summary.contains("1 files corrected"), "{}", r.summary);
    assert_eq!(
        hub.text(&main, "a.txt").unwrap().as_deref(),
        Some(resolved.as_str())
    );
    let author = hub.with(|h| h.author_of(r.author).unwrap().unwrap());
    assert_eq!(author["reason"], "merge");
}

/// The shell: a task's tree of the same project is merged as the union; a tree of another project (a snapshot task's
/// own repository) only as git's result.
#[tokio::test(flavor = "multi_thread")]
async fn record_unions_only_one_projects_trees() {
    let f = Fx::new();
    let state = tempfile::tempdir().unwrap();
    let hubs = Hubs::default();
    let (hub, _) = hubs.of_tree(state.path(), &f.task).unwrap();
    f.agent_writes(&hub, &BASE.replace("l2", "agent"));
    let old = git(&f.main, &["rev-parse", "HEAD"]);
    ok(&f.main, &["merge", "-q", "--no-ff", "-m", "merge t", "t"]);
    super::record(&hubs, state.path(), &f.main, &f.task, Some(old.clone())).await;
    let kinds = |hub: &Hub| {
        hub.with(|h| {
            (1..=h.count("op").unwrap())
                .map(|i| h.op(OpId(i)).unwrap().kind)
                .collect::<Vec<_>>()
        })
    };
    assert_eq!(kinds(&hub), [Kind::AgentStep, Kind::Merge]);
    // another project's tree: git's result only
    let other = tempfile::tempdir().unwrap();
    git(other.path(), &["init", "-q", "-b", "main"]);
    ok(&f.main, &["checkout", "-q", "-b", "u"]);
    std::fs::write(f.main.join("a.txt"), "u\n").unwrap();
    ok(&f.main, &["commit", "-q", "-am", "u"]);
    let before = ok(&f.main, &["checkout", "-q", "main"]);
    ok(&f.main, &["merge", "-q", "--no-ff", "-m", "merge u", "u"]);
    super::record(&hubs, state.path(), &f.main, other.path(), Some(before)).await;
    assert_eq!(
        kinds(&hub),
        [Kind::AgentStep, Kind::Merge, Kind::External],
        "no union with a tree of another project"
    );
}

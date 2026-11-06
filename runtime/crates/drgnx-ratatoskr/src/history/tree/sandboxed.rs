//! A commit in an agent's tree inside a real Gleipnir child (pattern C: the child's exit is what each test waits for,
//! then the ref files are read).  The sandbox is a hard requirement, so these are the sandbox lane's (`#[ignore]`,
//! run with `-- --ignored` in a `ctr.sh --sandbox` container after `cargo build -p drgnx-ratatoskr --bin ratatoskr`,
//! whose binary is the sandbox's helper).  Fixtures live under /tmp/glp-XXXXXX, which is HOME and the runtime dir.

use super::*;
use gleipnir::{Sandbox, Tier};
use runstav::paths::Env;

struct Fx {
    _dir: tempfile::TempDir,
    b: PathBuf,
}

impl Fx {
    fn new() -> Fx {
        let dir = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap();
        let b = std::fs::canonicalize(dir.path()).unwrap();
        for d in ["home", "run", "t"] {
            std::fs::create_dir_all(b.join(d)).unwrap();
        }
        Fx { _dir: dir, b }
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.b.join(rel)
    }

    fn env(&self) -> Env {
        let s = |rel: &str| self.p(rel).to_str().unwrap().to_owned();
        Env::new(
            &[
                ("HOME", &s("home")),
                ("XDG_RUNTIME_DIR", &s("run")),
                ("TMPDIR", &s("t")),
                ("PATH", "/usr/bin:/bin"),
            ],
            rustix::process::geteuid().as_raw(),
        )
    }

    /// A repository at REL with `a.txt` committed.
    fn repo(&self, rel: &str) -> PathBuf {
        let d = self.p(rel);
        std::fs::create_dir_all(&d).unwrap();
        git(&d, &["init", "-q", "-b", "main"]);
        std::fs::write(d.join("a.txt"), "one").unwrap();
        git(&d, &["add", "a.txt"]);
        git(&d, &["commit", "-q", "-m", "base"]);
        d
    }
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {out:?}");
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// The full tier, its helper this build's `ratatoskr` (beside the test binary's folder).
fn sandbox() -> Sandbox {
    let exe = std::env::current_exe().unwrap();
    let bin = exe.parent().unwrap().parent().unwrap().join("ratatoskr");
    assert!(
        bin.exists(),
        "build the ratatoskr binary first: {}",
        bin.display()
    );
    Sandbox::detect(Tier::Full, crate::sandbox::helper_at(&bin), None)
        .unwrap_or_else(|r| panic!("the full tier is not usable here: {r}"))
}

/// A finished worker's tree (no session row: nothing of its launch is read) committed inside the sandbox: one forward
/// commit with the subject, read from the ref files, and the launch made the session's own folder.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "the sandbox lane: a real Gleipnir child"]
async fn commit_runs_inside_the_sandbox() {
    let fx = Fx::new();
    let wt = fx.repo("wt");
    std::fs::write(wt.join("a.txt"), "two").unwrap();
    let (sb, env) = (sandbox(), fx.env());
    let before = snapshot::head_of(&wt);
    let made = commit_with(
        Some((&sb, &env)),
        "S1",
        &wt,
        &[PathBuf::from("a.txt")],
        "revert to step 3",
    )
    .await
    .unwrap();
    assert!(made.is_some() && made != before, "{made:?}");
    assert_eq!(made, snapshot::head_of(&wt));
    assert_eq!(git(&wt, &["log", "-1", "--format=%s"]), "revert to step 3");
    // the worktree's own index matches the commit (the sandbox's placeholders for the absent protected files,
    // `.envrc` and `mise.toml`, stay untracked, as after any launch), and the commit's index is gone
    assert_eq!(
        git(&wt, &["status", "--porcelain", "--untracked-files=no"]),
        ""
    );
    assert!(!wt.join(".git").join(COMMIT_INDEX).exists());
    let dir = runstav::paths::session_dir(&env, &runstav::paths::socket_path(&env), "S1").unwrap();
    assert!(dir.is_dir(), "{}", dir.display());
}

/// The same session's commit for a finished worker: there is no row and no entity to read, and the commit is the same.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "the sandbox lane: a real Gleipnir child"]
async fn commit_for_a_finished_worker_uses_its_entity() {
    let fx = Fx::new();
    let wt = fx.repo("wt");
    std::fs::remove_file(wt.join("a.txt")).unwrap();
    std::fs::write(wt.join("b.txt"), "new").unwrap();
    let (sb, env) = (sandbox(), fx.env());
    let paths = [PathBuf::from("a.txt"), PathBuf::from("b.txt")];
    let made = commit_with(Some((&sb, &env)), "S2", &wt, &paths, "revert")
        .await
        .unwrap();
    assert!(made.is_some());
    assert_eq!(git(&wt, &["ls-files"]), "b.txt");
    // again after a crash: the deletion is committed already, so neither side has a.txt; nothing to commit, quiet
    let again = commit_with(Some((&sb, &env)), "S2", &wt, &paths, "revert").await;
    assert_eq!(again, Ok(None));
}

/// A linked worktree's commit must write the common folder, outside the tree: the sandbox refuses it, the error says
/// so, and the files stand.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "the sandbox lane: a real Gleipnir child"]
async fn commit_in_a_linked_worktree_is_reported_not_fatal() {
    let fx = Fx::new();
    let main = fx.repo("main");
    let lw = fx.p("lw");
    git(
        &main,
        &["worktree", "add", "-q", "-b", "side", lw.to_str().unwrap()],
    );
    std::fs::write(lw.join("a.txt"), "changed").unwrap();
    let (sb, env) = (sandbox(), fx.env());
    let before = snapshot::head_of(&lw);
    let r = commit_with(
        Some((&sb, &env)),
        "S3",
        &lw,
        &[PathBuf::from("a.txt")],
        "revert",
    )
    .await;
    assert!(r.is_err(), "{r:?}");
    assert_eq!(snapshot::head_of(&lw), before);
    assert_eq!(
        std::fs::read_to_string(lw.join("a.txt")).unwrap(),
        "changed"
    );
}

/// A git that fails (a repository with no commit: HEAD cannot be read): the error carries git's message, and nothing
/// else changed.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "the sandbox lane: a real Gleipnir child"]
async fn commit_failure_is_reported_not_fatal() {
    let fx = Fx::new();
    let wt = fx.p("wt");
    std::fs::create_dir_all(&wt).unwrap();
    git(&wt, &["init", "-q", "-b", "main"]);
    std::fs::write(wt.join("a.txt"), "two").unwrap();
    let (sb, env) = (sandbox(), fx.env());
    let r = commit_with(
        Some((&sb, &env)),
        "S4",
        &wt,
        &[PathBuf::from("a.txt")],
        "revert",
    )
    .await;
    let e = r.unwrap_err();
    assert!(e.contains("HEAD"), "{e}");
    assert_eq!(snapshot::head_of(&wt), None);
    assert_eq!(std::fs::read_to_string(wt.join("a.txt")).unwrap(), "two");
}

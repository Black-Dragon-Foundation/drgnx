//! Writing into an agent's tree (`docs/develop/hub.md`, "Revert to here"): which paths the hub may write there
//! ([`restorable`]), a commit there inside the session's own sandbox ([`commit_in_sandbox`]), and a fork's new tree at
//! a checkpoint ([`fork_tree`]).  Every write into a tree goes through `eitri` (`timeline::snapshot::restore_into`),
//! so no link is followed and a checkpoint never widens a sandbox.
#![cfg_attr(
    not(test),
    expect(dead_code, reason = "the revert and the fork methods call them")
)]

use crate::agents::launch::{self, NetCell, SandboxReq};
use crate::agents::lock::{Enforced, LaunchPlan, NEVER_RESTORED, PROTECTED_RO};
use crate::agents::rewind::Target;
use crate::agents::session::{internal, invalid};
use crate::front::Front;
use crate::runner::{TaskTree, TreeMode};
use crate::timeline::snapshot;
use runstav::methods::matrix::Role;
use runstav::wire::Error;
use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

/// How long a commit in an agent's tree may take.
const COMMIT_TIMEOUT: Duration = Duration::from_secs(60);

/// Whether the hub may write REL into an agent's tree: never a path of the lock's [`NEVER_RESTORED`] (the list a
/// runner's returned patch is refused by too) at any depth, never anything with a `.git` component (`config` and
/// `config.worktree` are pinned by the sandbox but are not in the lock's list), never a secret file the snapshots
/// leave out (`snapshot::excludes`, with EXTRA, the settings' secret paths).  Compared component by component; on
/// macOS case-folded too, as its default volume is.
pub(crate) fn restorable(rel: &Path, extra: &[String]) -> bool {
    let fold = |s: &str| {
        if cfg!(target_os = "macos") {
            s.to_lowercase()
        } else {
            s.to_owned()
        }
    };
    let parts: Vec<String> = rel
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(fold(&s.to_string_lossy())),
            _ => None,
        })
        .collect();
    if parts.is_empty() || parts.iter().any(|p| p == ".git") {
        return false;
    }
    for e in NEVER_RESTORED {
        let want: Vec<String> = e.split('/').map(fold).collect();
        if parts.windows(want.len()).any(|w| w == want.as_slice()) {
            return false;
        }
    }
    let path = parts.join("/");
    !snapshot::excludes(extra)
        .iter()
        .filter_map(|x| x.strip_prefix(":(exclude,glob)"))
        .any(|g| crate::runners::returned::glob_ok(&fold(g), &path))
}

/// The index a commit is built in, beside the worktree's own (`.git/drgnx-commit-index`).
const COMMIT_INDEX: &str = "drgnx-commit-index";

/// One git run of a commit: its arguments and whether it uses the commit's own index.
struct Run {
    argv: Vec<OsString>,
    own_index: bool,
}

/// The git runs of a commit of PATHS with SUBJECT, with no hook and no signing, as `git commit --only` does it but
/// quiet about a path neither side has (a deletion committed already, a file the agent never added): HEAD read into
/// the commit's own index, the paths updated there (a missing one removed), the index compared with HEAD (exit 0:
/// nothing to commit), committed, and the same paths updated in the worktree's index so it matches the new commit.
fn commit_runs(paths: &[PathBuf], subject: &str) -> [Run; 5] {
    let git = |rest: &[&str], with_paths: bool, own_index: bool| {
        let mut argv: Vec<OsString> = [
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "user.name=drgnx",
            "-c",
            "user.email=drgnx@localhost",
        ]
        .iter()
        .chain(rest)
        .map(OsString::from)
        .collect();
        if with_paths {
            argv.extend(paths.iter().map(|p| p.as_os_str().to_owned()));
        }
        Run { argv, own_index }
    };
    let update = ["update-index", "--add", "--remove", "--"];
    [
        git(&["read-tree", "HEAD"], false, true),
        git(&update, true, true),
        git(
            &["diff-index", "--cached", "--quiet", "HEAD", "--"],
            false,
            true,
        ),
        git(&["commit", "--no-verify", "-q", "-m", subject], false, true),
        git(&update, true, false),
    ]
}

/// The worktree's git folder: `.git`, or the folder its `.git` file names (a linked worktree).
fn git_dir(cwd: &Path) -> PathBuf {
    let dot = cwd.join(".git");
    if dot.is_dir() {
        return dot;
    }
    std::fs::read_to_string(&dot)
        .ok()
        .and_then(|s| s.trim_end().strip_prefix("gitdir: ").map(|g| cwd.join(g)))
        .unwrap_or(dot)
}

/// How one git run ended: its exit (none: it did not finish) and the end of its stderr.
type Ran = (Option<i32>, String);

/// ARGV in CWD with the hub's own rights (a folder no sandboxed agent worked in), with ENV.
fn plain(cwd: &Path, argv: &[OsString], env: &[(String, String)]) -> Result<Ran, String> {
    let out = std::process::Command::new(&argv[0])
        .args(&argv[1..])
        .envs(env.iter().map(|(k, v)| (k, v)))
        .current_dir(cwd)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("git: {e}"))?;
    Ok((
        out.status.code(),
        String::from_utf8_lossy(&out.stderr).trim().to_owned(),
    ))
}

/// ARGV with VARS in the sandbox SB as session SID's, in its worktree CWD: CWD the only writable folder, the lock's
/// protected paths and the git folder's hooks and config read-only (`launch::worktree_launch`), no network but the
/// provider's relay (which a commit never uses).  The status line is read before the exit is awaited.  The
/// placeholders the launch made to pin absent protected files (`.envrc`, `mise.toml`) go once it ends: a one-shot run
/// ends no session, so nothing else would remove them; the session's own, from its launch, stay.
pub(crate) async fn sandboxed_in(
    sb: &gleipnir::Sandbox,
    env: &runstav::paths::Env,
    sid: &str,
    cwd: &Path,
    argv: Vec<OsString>,
    vars: Vec<(String, String)>,
) -> Result<Ran, String> {
    let scratch = launch::scratch_path(env, sid);
    let mark = crate::sandbox::stubs_mark(&scratch);
    let r = sandboxed_run(sb, env, sid, cwd, argv, vars).await;
    crate::sandbox::remove_stubs_since(&scratch, cwd, mark);
    r
}

async fn sandboxed_run(
    sb: &gleipnir::Sandbox,
    env: &runstav::paths::Env,
    sid: &str,
    cwd: &Path,
    argv: Vec<OsString>,
    vars: Vec<(String, String)>,
) -> Result<Ran, String> {
    let plan = LaunchPlan {
        argv,
        env: vars,
        session_meta: None,
        protected_ro: PROTECTED_RO.iter().map(PathBuf::from).collect(),
        login_dir: None,
        enforced: Enforced::Yes,
        gateway: false,
        trace: None,
    };
    let req = SandboxReq {
        sid: sid.to_owned(),
        worktree: cwd.to_path_buf(),
        read: vec![],
        net: NetCell::ProviderOnly,
        role: Role::Worker,
    };
    let (plan, shape) = launch::worktree_launch(&plan, &req);
    let l = launch::launch_on(env, sb, &plan, &shape).map_err(|r| r.message)?;
    let mut child = draugr::spawn_pinned(l.spec)
        .await
        .map_err(|e| format!("the sandbox did not start: {e}"))?;
    if let Some(fd) = l.status {
        gleipnir::inner::read_status_for(fd, &|| child.stderr_tail(), COMMIT_TIMEOUT, false)
            .map_err(|r| format!("the sandbox did not start: {r}"))?;
    }
    let exit = match crate::clock::timeout(COMMIT_TIMEOUT, child.wait()).await {
        Ok(Ok(Some(s))) => s.code(),
        _ => {
            let _ =
                draugr::kill_group(child.id(), draugr::reap::GRACE, &draugr::RealSignaller).await;
            None
        }
    };
    Ok((exit, child.stderr_tail()))
}

/// PATHS of CWD committed as one forward commit with SUBJECT ([`commit_runs`]): in a folder a sandboxed agent worked
/// in, inside a sandbox of session SID's own shape ([`sandboxed_in`]), else with plain git.  The new commit is read
/// from the ref files after it (`snapshot::head_of`; a sandboxed run has no stdout).  Nothing to commit is `Ok(None)`,
/// so a retry after a crash is quiet; a failure is the error's text (the files stand).  In a linked worktree a
/// sandboxed commit cannot reach the common folder, and fails.
pub(crate) async fn commit_in_sandbox(
    front: &Front,
    sid: &str,
    cwd: &Path,
    paths: &[PathBuf],
    subject: &str,
) -> Result<Option<String>, String> {
    if paths.is_empty() {
        return Ok(None);
    }
    let touched = front.core.runs.git().is_touched(cwd).await.unwrap_or(true);
    let sb = if touched {
        Some(launch::detect().await.map_err(|r| r.message)?)
    } else {
        None
    };
    let env = front.shell_env.paths_env();
    commit_with(sb.as_ref().map(|s| (s, &env)), sid, cwd, paths, subject).await
}

/// [`commit_in_sandbox`] in the sandbox SB with the hub's environment (none: plain git).
pub(crate) async fn commit_with(
    sb: Option<(&gleipnir::Sandbox, &runstav::paths::Env)>,
    sid: &str,
    cwd: &Path,
    paths: &[PathBuf],
    subject: &str,
) -> Result<Option<String>, String> {
    let before = snapshot::head_of(cwd);
    let index = git_dir(cwd).join(COMMIT_INDEX);
    let r = async {
        for (i, run) in commit_runs(paths, subject).into_iter().enumerate() {
            let vars = if run.own_index {
                vec![(
                    "GIT_INDEX_FILE".to_owned(),
                    index.to_string_lossy().into_owned(),
                )]
            } else {
                vec![]
            };
            let (exit, stderr) = match sb {
                Some((sb, env)) => sandboxed_in(sb, env, sid, cwd, run.argv, vars).await?,
                None => {
                    let dir = cwd.to_path_buf();
                    crate::clock::blocking(move || plain(&dir, &run.argv, &vars))
                        .await
                        .map_err(|e| e.to_string())??
                }
            };
            match (i, exit) {
                // the commit's index is HEAD's: nothing to commit
                (2, Some(0)) => return Ok(None),
                // it differs from HEAD (2, exit 1), or the run did its part
                (2, Some(1)) | (_, Some(0)) => {}
                _ => {
                    return Err(format!(
                        "the commit failed (exit {exit:?}): {}",
                        if stderr.is_empty() {
                            "no message"
                        } else {
                            &stderr
                        }
                    ));
                }
            }
        }
        let after = snapshot::head_of(cwd);
        Ok(after.filter(|a| Some(a) != before.as_ref()))
    }
    .await;
    // the commit's own index goes (never through a link: `eitri`); a linked worktree's lies outside, and stays
    if let Ok(dir) = std::fs::File::open(cwd) {
        use std::os::fd::AsFd;
        let _ = eitri::remove_beneath(dir.as_fd(), &Path::new(".git").join(COMMIT_INDEX));
    }
    r
}

/// The branch WORKTREE's HEAD names (`.git/HEAD` read through `eitri`: no link followed, no git run there); none for a
/// detached head, a linked worktree or a name that is not a plain branch name.  An agent writes the file: a hint.
fn branch_of(worktree: &Path) -> Option<String> {
    use std::os::fd::AsFd;
    let dir = std::fs::File::open(worktree).ok()?;
    let head = eitri::read_regular(dir.as_fd(), Path::new(".git/HEAD"), 4096).ok()?;
    let name = String::from_utf8(head)
        .ok()?
        .trim_end()
        .strip_prefix("ref: refs/heads/")?
        .to_owned();
    let plain = !name.is_empty()
        && !name.starts_with('-')
        && name
            .split('/')
            .all(|p| !p.is_empty() && p != "." && p != ".." && !p.starts_with('.'))
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '_' | '-' | '+'));
    plain.then_some(name)
}

/// Whether COMMIT is a commit REPO has (`cat-file -e`, in the trusted repository).
fn verifies(repo: &Path, commit: &str) -> bool {
    crate::runner::effects::git(repo, &["cat-file", "-e", &format!("{commit}^{{commit}}")]).is_ok()
}

/// A new tree for session NEW_SID at SOURCE's checkpoint: a task tree of the source's repository (`fork-<sid8>`,
/// task NEW_SID) at the step's head when that commit verifies in the trusted repository (a snapshot task's branch is
/// imported there through its bundle first, `RunGit::import`), else at the worktree's
/// recorded base (`worktree_base.base_commit`), with the checkpoint written over it (`snapshot::restore_into`: by
/// mode, through `eitri`, never a protected path), then marked touched.  The repository is the worktree's recorded
/// one, else the source's own folder when no sandboxed agent worked there.
pub(crate) async fn fork_tree(
    front: &Front,
    source: &Target,
    new_sid: &str,
) -> Result<TaskTree, Error> {
    let (_, cwd, _) =
        crate::agents::rewind::source_of(&front.core.agents, front, &source.sid).await?;
    let (key, seq, cw) = (
        format!("session:{}", source.sid),
        source.seq,
        cwd.to_string_lossy().into_owned(),
    );
    let (step, base_row) = front
        .writer
        .db
        .read(move |c| {
            let step = norn::read::steps::for_session(c, &key, seq - 1)?
                .into_iter()
                .find(|s| s.seq == seq);
            Ok((step, norn::read::work::base(c, &cw)?))
        })
        .await
        .map_err(|e| internal(format!("the source's step: {e}")))?;
    let step = step.ok_or_else(|| {
        invalid(
            "seq",
            format!("session {} has no step {}", source.sid, source.seq),
        )
    })?;
    let root = front
        .dirs
        .get()
        .map(|d| d.hub.join("checkpoints"))
        .ok_or_else(|| internal("the hub has no state folder"))?;
    let git = front.core.runs.git();
    let repo = match &base_row {
        Some(b) => PathBuf::from(&b.repo),
        None if !git.is_touched(&cwd).await.unwrap_or(true) => cwd.clone(),
        None => {
            return Err(invalid(
                "seq",
                "not-revertible: the source's repository is not recorded",
            ));
        }
    };
    // a snapshot task's commits are in its own folder only: its branch comes into the trusted repository through its
    // bundle first (verified, fsck'd, written compare-and-swap), so the step's head can verify there
    if git.mode() == TreeMode::Snapshot
        && let (Some(h), Some(b)) = (
            step.head.clone(),
            base_row.as_ref().and_then(|b| b.base_commit.clone()),
        )
        && let Some(branch) = branch_of(&cwd)
    {
        let (r, h2) = (repo.clone(), h);
        let known = crate::clock::blocking(move || verifies(&r, &h2))
            .await
            .unwrap_or(false);
        if !known {
            let src = TaskTree {
                path: cwd.clone(),
                branch,
                base: b,
                mode: TreeMode::Snapshot,
            };
            if let Err(e) = git.import(&repo, &src).await {
                tracing::info!(
                    sid = source.sid,
                    "the task's branch is not imported: {}: {}",
                    e.what,
                    e.stderr
                );
            }
        }
    }
    let (r, head, recorded) = (
        repo.clone(),
        step.head.clone(),
        base_row.and_then(|b| b.base_commit),
    );
    let base = crate::clock::blocking(move || {
        head.filter(|h| verifies(&r, h))
            .or_else(|| recorded.filter(|b| verifies(&r, b)))
    })
    .await
    .map_err(|e| internal(e.to_string()))?
    .ok_or_else(|| {
        invalid(
            "seq",
            "not-revertible: neither the step's head nor the worktree's base is a commit the repository has",
        )
    })?;
    let (root2, cwd2, sid, seq) = (root.clone(), cwd.clone(), source.sid.clone(), source.seq);
    let checkpoint = match step.snapshot.clone() {
        Some(t) => Some(t),
        None => crate::clock::blocking(move || snapshot::tree_at(&root2, &cwd2, &sid, seq))
            .await
            .map_err(|e| internal(e.to_string()))?,
    }
    .ok_or_else(|| invalid("seq", "not-revertible: the step has no checkpoint"))?;
    let sid8: String = new_sid.chars().take(8).collect();
    let tree = git
        .task_worktree(&repo, &format!("fork-{sid8}"), new_sid, &base)
        .await
        .map_err(|e| internal(format!("the fork's tree: {}: {}", e.what, e.stderr)))?;
    let (path, src) = (tree.path.clone(), cwd.clone());
    let restored = crate::clock::blocking(move || {
        snapshot::restore_into(&root, &src, &path, &checkpoint, None, &[])
    })
    .await
    .map_err(|e| internal(e.to_string()))?
    .map_err(|e| internal(format!("the checkpoint is not written into the fork: {e}")))?;
    if !restored.skipped.is_empty() {
        tracing::info!(sid = new_sid, skipped = ?restored.skipped, "the fork's tree leaves paths out");
    }
    if let Err(e) = git.touched(&tree.path).await {
        tracing::warn!(
            sid = new_sid,
            "the fork's tree is not marked touched: {}",
            e.stderr
        );
    }
    Ok(tree)
}

#[cfg(test)]
mod tests;

#[cfg(all(test, target_os = "linux"))]
mod sandboxed;

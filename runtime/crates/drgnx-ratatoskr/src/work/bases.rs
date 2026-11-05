//! Where a worktree branched from, recorded when the hub makes it (docs/develop/work-space.md, "Worktree bases").
//!
//! The base is a fact of git at that moment, written by the hub as `("hub", System)`: the repository, the branch the
//! worktree was cut from (never `main` unless that is the branch), the commit, and a tree of the new worktree kept in
//! its shadow repository (`timeline::snapshot::take_base`) that the interim diffs measure from, so nothing ever runs
//! git inside an agent's tree. A session in a folder the hub did not make a worktree for (a docs agent in the org
//! folder) is measured from that folder's head at its start.
//!
//! The git here runs in the trusted repository (or, for a session's start, in the user's own folder before the agent
//! runs), never in a tree an agent writes.

use crate::coord::Writer;
use crate::dispatch::Caller;
use crate::timeline::snapshot;
use norn::write::work::WorktreeBase;
use runstav::methods::work::Workspace;
use runstav::registry::Class;
use std::path::{Path, PathBuf};
use std::process::Command;

/// A branch of a repository.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct BranchRef {
    pub repo: PathBuf,
    pub branch: String,
}

/// Git's answer in DIR (a trusted folder), or none when it fails or says nothing.
fn git_in(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!text.is_empty()).then_some(text)
}

/// The branch BASE names, or the one local branch (not NEW_BRANCH) that points at BASE; when several do, the run's own
/// `job/<run>` for a tree named `job/<run>-<task>`, else none. Never a guess, and never `main` because it is the
/// default.
pub fn branch_for(repo: &Path, base: &str, new_branch: &str) -> Option<String> {
    if git_in(
        repo,
        &["rev-parse", "--verify", "-q", &format!("refs/heads/{base}")],
    )
    .is_some()
    {
        return Some(base.to_string());
    }
    let listed = git_in(
        repo,
        &[
            "for-each-ref",
            "--points-at",
            base,
            "--format=%(refname:short)",
            "refs/heads/",
        ],
    )?;
    let names: Vec<&str> = listed.lines().filter(|b| *b != new_branch).collect();
    match names.as_slice() {
        [one] => Some((*one).to_string()),
        // a plan run's tree is `job/<run>-<task>`, cut from the run's own branch `job/<run>`
        many => {
            let mut own = many
                .iter()
                .filter(|c| c.starts_with("job/") && new_branch.starts_with(&format!("{c}-")));
            match (own.next(), own.next()) {
                (Some(c), None) => Some((*c).to_string()),
                _ => None,
            }
        }
    }
}

fn row(
    snap_root: &Path,
    repo: &Path,
    worktree: &Path,
    key: &str,
    base_branch: Option<String>,
    base_commit: Option<String>,
) -> WorktreeBase {
    WorktreeBase {
        worktree: worktree.to_string_lossy().into_owned(),
        repo: repo.to_string_lossy().into_owned(),
        base_branch,
        base_commit,
        base_tree: snapshot::take_base(snap_root, worktree, key),
        at: crate::clock::wall_secs(),
    }
}

/// The row for a worktree the hub just made for NEW_BRANCH in REPO, cut from BASE (a branch name or a commit), with its
/// base tree. Blocking: callers run it off the async threads.
pub fn row_for(
    snap_root: &Path,
    repo: &Path,
    worktree: &Path,
    base: &str,
    new_branch: &str,
) -> WorktreeBase {
    let commit = git_in(
        repo,
        &["rev-parse", "--verify", "-q", &format!("{base}^{{commit}}")],
    );
    row(
        snap_root,
        repo,
        worktree,
        new_branch,
        branch_for(repo, base, new_branch),
        commit,
    )
}

/// The row for a session working in CWD, a folder the hub made no worktree for: measured from the folder's head now.
/// None when CWD is not in a git repository. Blocking.
pub fn session_base(snap_root: &Path, cwd: &Path, key: &str) -> Option<WorktreeBase> {
    let repo = PathBuf::from(git_in(cwd, &["rev-parse", "--show-toplevel"])?);
    let commit = git_in(cwd, &["rev-parse", "--verify", "-q", "HEAD"]);
    let branch = git_in(cwd, &["symbolic-ref", "-q", "--short", "HEAD"]);
    Some(row(snap_root, &repo, cwd, key, branch, commit))
}

fn caller() -> Caller {
    Caller {
        class: Class::Service,
        sid: None,
        job: None,
        conn_id: 0,
    }
}

/// Write ROW (replacing the one of the same worktree). Best effort: a store that is not ready loses the row.
pub async fn put(writer: &Writer, row: WorktreeBase) {
    let worktree = row.worktree.clone();
    if let Err(e) = writer
        .write(&caller(), "work/base", move |tx| {
            norn::write::work::put_base(tx, row)
        })
        .await
    {
        tracing::warn!(worktree, "worktree base not recorded: {e}");
    }
}

/// Record that WT (in REPO) was cut from BASE_BRANCH at BASE_COMMIT, with a snapshot of it now.
pub async fn record(
    front: &crate::front::Front,
    wt: &Path,
    repo: &Path,
    base_branch: Option<&str>,
    base_commit: &str,
) {
    let Some(dirs) = front.dirs.get() else { return };
    let (root, repo, wt) = (
        dirs.hub.join("checkpoints"),
        repo.to_path_buf(),
        wt.to_path_buf(),
    );
    let (branch, commit) = (base_branch.map(str::to_string), base_commit.to_string());
    let key = wt
        .file_name()
        .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
    let Ok(r) =
        crate::clock::blocking(move || row(&root, &repo, &wt, &key, branch, Some(commit)))
            .await
    else {
        return;
    };
    put(&front.writer, r).await;
}

/// A session starts in CWD, a folder the hub did not make for it (not under HUB's `runs`, where the trees of plan runs
/// and workers are, and which record their own base): record the folder's head as the session's base, unless a row
/// for the folder is there.
pub async fn session_started(writer: Writer, hub: PathBuf, session: String, cwd: PathBuf) {
    if cwd.starts_with(hub.join("runs")) {
        return;
    }
    let wt = cwd.to_string_lossy().into_owned();
    let known = writer
        .db
        .read(move |c| Ok(norn::read::work::base(c, &wt)?.is_some()))
        .await
        .unwrap_or(true);
    if known {
        return;
    }
    let root = hub.join("checkpoints");
    if let Ok(Some(r)) =
        crate::clock::blocking(move || session_base(&root, &cwd, &session)).await
    {
        put(&writer, r).await;
    }
}

/// "Based on" pairs for the rows whose repository is under one of ROOTS: the worktree's branch (`job/<run>-<task>`, from
/// the folder the hub made it in) on the branch it was cut from. Rows with no base branch, and a session's own folder,
/// make no pair.
pub fn ancestry_of(rows: &[WorktreeBase], roots: &[PathBuf]) -> Vec<(BranchRef, BranchRef)> {
    let mut out: Vec<(BranchRef, BranchRef)> = rows
        .iter()
        .filter_map(|r| {
            let repo = PathBuf::from(&r.repo);
            if !roots.iter().any(|root| repo.starts_with(root)) {
                return None;
            }
            let parent = r.base_branch.clone()?;
            let wt = Path::new(&r.worktree);
            if wt == repo {
                return None;
            }
            let task = wt.file_name()?.to_string_lossy().into_owned();
            let run = wt.parent()?.file_name()?.to_string_lossy().into_owned();
            Some((
                BranchRef {
                    repo: repo.clone(),
                    branch: format!("job/{run}-{task}"),
                },
                BranchRef {
                    repo,
                    branch: parent,
                },
            ))
        })
        .collect();
    out.sort();
    out.dedup();
    out
}

/// [`ancestry_of`] over every row in the store, for WS's roots.
pub async fn ancestry(front: &crate::front::Front, ws: &Workspace) -> Vec<(BranchRef, BranchRef)> {
    let rows = front
        .writer
        .db
        .read(|c| {
            let mut q = c.prepare(
                "select worktree, repo, base_branch, base_commit, base_tree, at from worktree_base",
            )?;
            let rows = q
                .query_map([], |r| {
                    Ok(WorktreeBase {
                        worktree: r.get(0)?,
                        repo: r.get(1)?,
                        base_branch: r.get(2)?,
                        base_commit: r.get(3)?,
                        base_tree: r.get(4)?,
                        at: r.get(5)?,
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap_or_default();
    ancestry_of(&rows, &ws.roots)
}

#[cfg(test)]
mod tests;

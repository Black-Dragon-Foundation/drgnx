//! The git actions of the source-control methods (`git/stage`, `git/commit`, `git/remote`, …): each runs the user's
//! git on a blocking thread with a deadline ([`run::LOCAL`], [`run::COMMIT`]); a remote command ([`remote`]) answers at
//! once and sends `scm-remote` when it starts and ends.  No view reads the repository again: a client asks for the
//! status it wants.

pub mod run;
#[cfg(test)]
mod tests;

use crate::dispatch::Caller;
use crate::front::Front;
use run::{As, GitError, LOCAL};
use runstav::methods::scm::{
    Branch, Branches, Checkout, Commit, Committed, DeleteBranch, Paths, Remote, RemoteEvent,
    RemoteId, RemoteOp, Root, Stash, StashOp,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::json;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};
use std::time::Duration;

/// The remote commands running, by id, and the front they report to.
#[derive(Default)]
pub struct Remotes {
    running: Mutex<BTreeMap<u64, Arc<AtomicBool>>>,
    next: AtomicU64,
    front: OnceLock<Weak<Front>>,
}

impl Remotes {
    /// Keep the front, for the threads that report a remote command's end.
    pub fn bind(&self, front: &Arc<Front>) {
        crate::soft::done(self.front.set(Arc::downgrade(front)), "git remotes");
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    saman::lock(m)
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

fn failed(message: String) -> Error {
    Error {
        code: ErrorCode::Internal,
        message,
        path: None,
    }
}

/// ROOT as a folder that is a repository's top.
fn repo_root(root: &str) -> Result<PathBuf, Error> {
    let p = PathBuf::from(root);
    if !p.join(".git").exists() {
        return Err(invalid("root", "the top folder of a git repository"));
    }
    Ok(p)
}

/// Run git ARGS in ROOT as WHO on a blocking thread (STDIN, DEADLINE).
async fn git_quiet(
    root: &Path,
    who: As,
    args: Vec<String>,
    stdin: Option<Vec<u8>>,
    deadline: Duration,
) -> Result<Vec<u8>, Error> {
    let r = root.to_path_buf();
    crate::clock::blocking(move || {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        run::git(&r, who, &args, stdin.as_deref(), Some(deadline), None)
    })
    .await
    .map_err(|e| failed(e.to_string()))?
    .map_err(|e| failed(e.message().to_owned()))
}

/// Run the user's git ARGS in ROOT on a blocking thread (STDIN, DEADLINE).
async fn user_git(
    root: PathBuf,
    args: Vec<String>,
    stdin: Option<Vec<u8>>,
    deadline: Duration,
) -> Result<Vec<u8>, Error> {
    git_quiet(&root, As::User, args, stdin, deadline).await
}

fn with_paths(head: &[&str], paths: &[String]) -> Vec<String> {
    head.iter()
        .map(|s| (*s).to_owned())
        .chain(std::iter::once("--".to_owned()))
        .chain(paths.iter().cloned())
        .collect()
}

/// Whether ROOT has a commit yet.
async fn has_head(root: &Path) -> bool {
    let r = root.to_path_buf();
    crate::clock::blocking(move || {
        run::git(
            &r,
            As::Reader,
            &["rev-parse", "--verify", "-q", "HEAD"],
            None,
            Some(LOCAL),
            None,
        )
        .is_ok()
    })
    .await
    .unwrap_or(false)
}

/// `git/stage`.
pub async fn stage(p: Paths) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    user_git(root, with_paths(&["add", "-A"], &p.paths), None, LOCAL).await?;
    Ok(true)
}

/// `git/unstage`: `restore --staged`, or before the first commit `rm --cached`.
pub async fn unstage(p: Paths) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let head: &[&str] = if has_head(&root).await {
        &["restore", "--staged"]
    } else {
        &["rm", "--cached", "-r", "-q"]
    };
    user_git(root, with_paths(head, &p.paths), None, LOCAL).await?;
    Ok(true)
}

/// `git/discard`: the unstaged changes of tracked paths, back to the index's text.
pub async fn discard(p: Paths) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    user_git(
        root,
        with_paths(&["restore", "--worktree"], &p.paths),
        None,
        LOCAL,
    )
    .await?;
    Ok(true)
}

/// `git/commit`.
pub async fn commit(p: Commit) -> Result<Committed, Error> {
    let root = repo_root(p.root.as_str())?;
    commit_quiet(&root, &p).await
}

async fn commit_quiet(root: &Path, p: &Commit) -> Result<Committed, Error> {
    if p.all {
        git_quiet(root, As::User, vec!["add".into(), "-A".into()], None, LOCAL).await?;
    }
    let mut args: Vec<String> = vec!["commit".into(), "-q".into()];
    if p.amend {
        args.push("--amend".into());
        if p.message.trim().is_empty() {
            args.push("--no-edit".into());
        }
    }
    let stdin = (!p.message.trim().is_empty()).then(|| p.message.clone().into_bytes());
    if stdin.is_some() {
        args.extend(["-F".into(), "-".into()]);
    }
    git_quiet(root, As::User, args, stdin, run::COMMIT).await?;
    let sha = git_quiet(
        root,
        As::Reader,
        vec!["rev-parse".into(), "HEAD".into()],
        None,
        LOCAL,
    )
    .await?;
    Ok(Committed {
        sha: String::from_utf8_lossy(&sha).trim().to_owned(),
    })
}

/// `git/undo-commit`.
pub async fn undo_commit(p: Root) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let args = ["reset", "--soft", "HEAD~1"].map(String::from).to_vec();
    user_git(root, args, None, LOCAL).await?;
    Ok(true)
}

/// The remote a branch with no upstream is published to: `origin`, else the only one.
fn publish_remote(root: &Path) -> String {
    let out = run::git(root, As::Reader, &["remote"], None, Some(LOCAL), None).unwrap_or_default();
    let names: Vec<String> = String::from_utf8_lossy(&out)
        .lines()
        .map(str::to_owned)
        .collect();
    if names.len() == 1 && names[0] != "origin" {
        names[0].clone()
    } else {
        "origin".to_owned()
    }
}

/// `git/remote`: answers its id at once; a thread runs OP and sends `scm-remote` when it starts and ends.
pub fn remote(f: &Front, c: &Caller, p: Remote) -> Result<RemoteId, Error> {
    let root = repo_root(p.root.as_str())?;
    let remotes = &f.core.git;
    let id = remotes.next.fetch_add(1, Ordering::Relaxed) + 1;
    let cancel = Arc::new(AtomicBool::new(false));
    lock(&remotes.running).insert(id, cancel.clone());
    let Some(front) = remotes.front.get().cloned() else {
        return Err(invalid("root", "the hub is starting"));
    };
    let (conn, op) = (c.conn_id, p.op);
    let root2 = root.clone();
    let event = move |f: &Front, state: &str, error: Option<String>| {
        let e = RemoteEvent {
            id,
            root: root_string(&root),
            op,
            state: state.to_owned(),
            error,
        };
        f.send_to(conn, "scm-remote", json!(e));
    };
    saman::spawn_thread("scm-remote", move || {
        if let Some(f) = front.upgrade() {
            event(&f, "running", None);
        }
        let steps: Vec<Vec<String>> = match op {
            RemoteOp::Push => vec![vec!["push".into()]],
            RemoteOp::Pull => vec![vec!["pull".into()]],
            RemoteOp::Fetch => vec![vec!["fetch".into()]],
            RemoteOp::Sync => vec![vec!["pull".into()], vec!["push".into()]],
            RemoteOp::Publish => {
                vec![vec![
                    "push".into(),
                    "-u".into(),
                    publish_remote(&root2),
                    "HEAD".into(),
                ]]
            }
        };
        let mut result: Result<Vec<u8>, GitError> = Ok(Vec::new());
        for s in steps {
            let args: Vec<&str> = s.iter().map(String::as_str).collect();
            result = run::git(&root2, As::User, &args, None, None, Some(&cancel));
            if result.is_err() {
                break;
            }
        }
        let Some(f) = front.upgrade() else { return };
        lock(&f.core.git.running).remove(&id);
        match result {
            Ok(_) => event(&f, "done", None),
            Err(e) if e.kind() == villa::Kind::Cancelled => event(&f, "stopped", None),
            Err(e) => event(&f, "failed", Some(e.message().to_owned())),
        }
    })
    .map_err(|e| invalid("root", &e.to_string()))?;
    Ok(RemoteId { id })
}

fn root_string(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// `git/remote-stop`: false when ID is not running.
pub fn remote_stop(f: &Front, p: RemoteId) -> Result<bool, Error> {
    Ok(match lock(&f.core.git.running).get(&p.id) {
        Some(c) => {
            c.store(true, Ordering::Relaxed);
            true
        }
        None => false,
    })
}

/// `git for-each-ref` OUTPUT (`%(refname)NUL%(committerdate:unix)NUL%(HEAD)` per line) as the picker lists it: local
/// branches, then remote ones (not `*/HEAD`), each newest first (git sorted them).
pub fn parse_branches(output: &[u8]) -> Vec<Branch> {
    let mut local = Vec::new();
    let mut remote = Vec::new();
    for l in String::from_utf8_lossy(output).lines() {
        let mut it = l.split('\0');
        let (Some(name), Some(time), head) = (it.next(), it.next(), it.next()) else {
            continue;
        };
        let time = time.parse().unwrap_or(0);
        let current = head == Some("*");
        if let Some(n) = name.strip_prefix("refs/heads/") {
            local.push(Branch {
                name: n.to_owned(),
                remote: false,
                current,
                time,
            });
        } else if let Some(n) = name.strip_prefix("refs/remotes/")
            && !n.ends_with("/HEAD")
        {
            remote.push(Branch {
                name: n.to_owned(),
                remote: true,
                current: false,
                time,
            });
        }
    }
    local.extend(remote);
    local
}

/// `git/branches`.
pub async fn branches(p: Root) -> Result<Branches, Error> {
    let root = repo_root(p.root.as_str())?;
    let out = crate::clock::blocking(move || {
        let args = [
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname)%00%(committerdate:unix)%00%(HEAD)",
            "refs/heads",
            "refs/remotes",
        ];
        run::git(&root, As::Reader, &args, None, Some(LOCAL), None)
    })
    .await
    .map_err(|e| failed(e.to_string()))?
    .map_err(|e| failed(e.message().to_owned()))?;
    Ok(Branches {
        branches: parse_branches(&out),
    })
}

/// `git/checkout`: a new branch (CREATE), a remote one as a local branch tracking it, else the branch.
pub async fn checkout(p: Checkout) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let b = p.branch.clone();
    let r = root.clone();
    let remote_only = !p.create
        && crate::clock::blocking(move || {
            let is = |r#ref: &str| {
                run::git(
                    &r,
                    As::Reader,
                    &["show-ref", "--verify", "-q", r#ref],
                    None,
                    Some(LOCAL),
                    None,
                )
                .is_ok()
            };
            !is(&format!("refs/heads/{b}")) && is(&format!("refs/remotes/{b}"))
        })
        .await
        .unwrap_or(false);
    let args: Vec<String> = if p.create {
        vec!["switch".into(), "-c".into(), p.branch]
    } else if remote_only {
        vec!["switch".into(), "--track".into(), p.branch]
    } else {
        vec!["switch".into(), p.branch]
    };
    user_git(root, args, None, LOCAL).await?;
    Ok(true)
}

/// `git/delete-branch`.
pub async fn delete_branch(p: DeleteBranch) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let flag = if p.force { "-D" } else { "-d" };
    user_git(
        root,
        vec!["branch".into(), flag.into(), p.branch],
        None,
        LOCAL,
    )
    .await?;
    Ok(true)
}

/// `git/stash`.
pub async fn stash(p: Stash) -> Result<bool, Error> {
    let root = repo_root(p.root.as_str())?;
    let args: Vec<String> = match p.op {
        StashOp::Push => vec!["stash".into(), "push".into(), "--include-untracked".into()],
        StashOp::Pop => vec!["stash".into(), "pop".into()],
    };
    user_git(root, args, None, LOCAL).await?;
    Ok(true)
}

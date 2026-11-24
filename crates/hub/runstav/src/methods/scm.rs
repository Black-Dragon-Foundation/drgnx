//! The Source Control view (`scm/*`) and the git commands it runs (`git/stage`, `git/commit`, …): the hub reads every
//! repository under the workspace's folders, sends the view its rows (the repositories, each one's branch, staged,
//! unstaged and conflicted changes, and its commit graph), and runs each git command on a thread of its own, so the
//! editor never waits on git (docs/develop/hub.md, "The Source Control view").

use super::method;
use crate::registry::Method;
use crate::types::AbsPath;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The most paths one call stages, unstages or discards.
pub const PATHS_MAX: usize = 10_000;
/// The longest commit message, in bytes.
pub const MESSAGE_MAX: usize = 1 << 20;
/// The longest branch name, in bytes.
pub const BRANCH_MAX: usize = 255;
/// The most workspace folders a view reads.
pub const ROOTS_MAX: usize = 64;

/// How a view lists each section's files: one row per file, or grouped in their folders.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ViewAs {
    #[default]
    List,
    Tree,
}

/// `scm/subscribe`: VIEW shows the Source Control of the repositories under ROOTS (the workspace's folders: each
/// repository in or under one, nested ones and linked worktrees too, at most 200). ACTIVE: the file in the editor
/// (its repository is selected at first, with every one that has changes).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Subscribe {
    pub view: String,
    pub roots: Vec<AbsPath>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active: Option<AbsPath>,
    #[serde(default)]
    pub view_as: ViewAs,
}

/// `scm/set`: a change to VIEW: the editor's file (ACTIVE), a repository shown or hidden (SELECT), list or tree
/// (VIEW_AS), a section, folder or the graph folded or unfolded (TOGGLE: its row's key), more of a graph (MORE: the
/// repository's root).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Set {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active: Option<AbsPath>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub select: Option<Select>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view_as: Option<ViewAs>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub toggle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub more: Option<AbsPath>,
    /// Read every shown repository again (Refresh, the editor's frame taking the focus).
    #[serde(default)]
    pub refresh: bool,
}

/// A repository shown (ON) or hidden in the view.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Select {
    pub root: AbsPath,
    pub on: bool,
}

/// The repository at ROOT and PATHS in it (relative, no `..`): `git/stage`, `git/unstage`, `git/discard`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Paths {
    pub root: AbsPath,
    pub paths: Vec<String>,
}

/// `git/commit`: commit what is staged in ROOT with MESSAGE; ALL stages every change first; AMEND rewrites the last
/// commit.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Commit {
    pub root: AbsPath,
    pub message: String,
    #[serde(default)]
    pub all: bool,
    #[serde(default)]
    pub amend: bool,
}

/// A commit made: its id.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Committed {
    pub sha: String,
}

/// The repository at ROOT: `git/branches`, `git/undo-commit`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Root {
    pub root: AbsPath,
}

/// A remote command.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum RemoteOp {
    Push,
    Pull,
    Fetch,
    /// Pull, then push.
    Sync,
    /// Push a branch with no upstream, setting it (`push -u origin HEAD`).
    Publish,
}

/// `git/remote`: run OP in ROOT; answers at once with its id, the event `scm-remote` says how it ended.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Remote {
    pub root: AbsPath,
    pub op: RemoteOp,
}

/// A remote command's id.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RemoteId {
    pub id: u64,
}

/// The event `scm-remote`: remote command ID in ROOT is running, done, failed (git's ERROR) or stopped.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RemoteEvent {
    pub id: u64,
    pub root: String,
    pub op: RemoteOp,
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// A branch for the picker.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Branch {
    pub name: String,
    pub remote: bool,
    pub current: bool,
    /// Its last commit's time, seconds since the epoch.
    pub time: i64,
}

/// `git/branches`' answer: local branches, then remote ones, each newest first.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Branches {
    pub branches: Vec<Branch>,
}

/// `git/checkout`: switch ROOT to BRANCH (CREATE: a new branch from HEAD; a remote branch `origin/x`: a local `x`
/// tracking it).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Checkout {
    pub root: AbsPath,
    pub branch: String,
    #[serde(default)]
    pub create: bool,
}

/// `git/delete-branch`: delete the local BRANCH of ROOT (FORCE: also when it is not merged).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DeleteBranch {
    pub root: AbsPath,
    pub branch: String,
    #[serde(default)]
    pub force: bool,
}

/// A stash command.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum StashOp {
    Push,
    Pop,
}

/// `git/stash`: OP in ROOT (push takes untracked files too).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Stash {
    pub root: AbsPath,
    pub op: StashOp,
}

/// A view id: `scm/close`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewId {
    pub view: String,
}

/// A path git takes: relative, not empty, no `..` part, no NUL.
pub fn check_path(path: &str) -> Result<(), Error> {
    if path.is_empty()
        || path.len() > 4096
        || path.starts_with('/')
        || path.contains('\0')
        || path.split('/').any(|p| p == "..")
    {
        return Err(super::invalid(
            "paths",
            "paths relative to the root, without `..`",
        ));
    }
    Ok(())
}

fn check_paths(p: &Paths) -> Result<(), Error> {
    if p.paths.is_empty() || p.paths.len() > PATHS_MAX {
        return Err(super::invalid("paths", "1 to 10000 paths"));
    }
    p.paths.iter().try_for_each(|p| check_path(p))
}

fn check_commit(p: &Commit) -> Result<(), Error> {
    if p.message.trim().is_empty() && !p.amend {
        return Err(super::invalid("message", "a commit message"));
    }
    if p.message.len() > MESSAGE_MAX || p.message.contains('\0') {
        return Err(super::invalid("message", "at most 1 MiB, no NUL"));
    }
    Ok(())
}

/// A branch name the user typed or picked: not empty, not an option, no NUL or control characters.
fn check_branch(b: &str) -> Result<(), Error> {
    if b.is_empty() || b.len() > BRANCH_MAX || b.starts_with('-') || b.chars().any(char::is_control)
    {
        return Err(super::invalid("branch", "a branch name"));
    }
    Ok(())
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "git/stage", GitStage(Paths) -> bool,
            classes: [User], writes: true,
            doc: "stage paths of a repository (git add), on a thread, with a deadline",
            check: check_paths,
        ),
        method!(
            "git/unstage", GitUnstage(Paths) -> bool,
            classes: [User], writes: true,
            doc: "unstage paths of a repository (git restore --staged), on a thread, with a deadline",
            check: check_paths,
        ),
        method!(
            "git/discard", GitDiscard(Paths) -> bool,
            classes: [User], writes: true,
            doc: "discard the unstaged changes of tracked paths (git restore --worktree, from the index); untracked files are the editor's to move to the trash",
            check: check_paths,
        ),
        method!(
            "git/commit", GitCommit(Commit) -> Committed,
            classes: [User], writes: true,
            doc: "commit what is staged (all: every change first; amend: rewrite the last commit) with the message on stdin; the repository's hooks run as in a terminal, and their output is the error",
            check: check_commit,
        ),
        method!(
            "git/undo-commit", GitUndoCommit(Root) -> bool,
            classes: [User], writes: true,
            doc: "undo the last commit, keeping its changes staged (git reset --soft HEAD~1)",
        ),
        method!(
            "git/remote", GitRemote(Remote) -> RemoteId,
            classes: [User], writes: true,
            doc: "push, pull, fetch, sync (pull then push) or publish a repository on a thread: answers its id at once; the event scm-remote says it ended; git/remote-stop stops it; a password prompt is refused (the user's credential helper and ssh agent are used)",
        ),
        method!(
            "git/remote-stop", GitRemoteStop(RemoteId) -> bool,
            classes: [User], writes: true,
            doc: "stop a running git/remote command",
        ),
        method!(
            "git/branches", GitBranches(Root) -> Branches,
            classes: [User], writes: false,
            doc: "a repository's branches for the picker: local, then remote, each newest first",
        ),
        method!(
            "git/checkout", GitCheckout(Checkout) -> bool,
            classes: [User], writes: true,
            doc: "switch a repository to a branch (create: a new one from HEAD; a remote one: a local branch tracking it)",
            check: |p: &Checkout| check_branch(&p.branch),
        ),
        method!(
            "git/delete-branch", GitDeleteBranch(DeleteBranch) -> bool,
            classes: [User], writes: true,
            doc: "delete a local branch of a repository (force: also when it is not merged)",
            check: |p: &DeleteBranch| check_branch(&p.branch),
        ),
        method!(
            "git/stash", GitStash(Stash) -> bool,
            classes: [User], writes: true,
            doc: "stash a repository's changes (untracked files too), or pop the last stash",
        ),
    ]
}

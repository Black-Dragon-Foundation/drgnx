//! Plan runs in the hub (`job/*` with `drgnx-job-summary` shapes; V2 runtime phase 6; `docs/develop/coordination.md`,
//! "Plan runs"): propose, approve, the 2 s tick (no git on it), start a task (Task 16a); review hand-off, fallback,
//! budget pause, cards (Task 16b).  The Lisp runner is the oracle for each rule.
//!
//! - [`git`]: [`RunGit`] for the hub: worktree and snapshot modes, the merge gate, trial merges (Task 17).
//! - [`clash`]: the five clash rules (Task 18).
//! - [`effects`]: `plans/*`, `reports/get`, `decisions/effects` (Task 21).

pub mod clash;
pub mod effects;
pub mod git;

use crate::agent_core::not_yet;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::matrix_gate::Gate;
use runstav::methods::agents::ById;
use runstav::methods::jobs::{
    BlockParams, ByMessage, ByTask, CardParams, JobStatusResult, JobSummary, OrderParams,
    ProposeParams, ReassignParams, ReplyParams, StartTaskParams, StatusParams, WithBudget,
};
use runstav::wire::Error;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;

/// The plan runs the hub holds (Tasks 16a, 16b fill it).
#[derive(Default)]
pub struct Runs {}

/// What a [`RunGit`] call answers.
pub type GitFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, GitError>> + Send + 'a>>;

/// A git step that failed (or ran past its deadline): what was run and what it said.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitError {
    pub what: String,
    pub stderr: String,
}

/// How a task's tree is kept: a worktree of the trusted repository, or a snapshot (a bare store per run, a reflink
/// copy per task, its bundle verified with fsck; V2 runtime §5.10).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TreeMode {
    Worktree,
    Snapshot,
}

/// A task's tree, made for its worker.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskTree {
    pub path: PathBuf,
    pub branch: String,
    /// The commit it starts from.
    pub base: String,
    pub mode: TreeMode,
}

/// A trial merge's outcome, in a scratch worktree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrialResult {
    pub clean: bool,
    pub conflicts: Vec<PathBuf>,
}

/// The runner's git, behind a trait so Task 16a runs on a fake while Task 17 writes `HubGit` ([`git`]).  Every call
/// is async with a deadline; none runs on the tick.
pub trait RunGit: Send + Sync {
    /// The tree for TASK of RUN, branched from BASE in REPO.
    fn task_worktree<'a>(
        &'a self,
        repo: &'a Path,
        run: &'a str,
        task: &'a str,
        base: &'a str,
    ) -> GitFuture<'a, TaskTree>;
    /// TASK's merge gate: the changed set from `git diff --raw` in the trusted repository, every path checked against
    /// the current diff hash; CI and build files and the protected paths ask (`code.ci-config`); `Allow` merges
    /// exactly the tip checked (`merge --no-ff`).
    fn merge_gate<'a>(&'a self, repo: &'a Path, tree: &'a TaskTree) -> GitFuture<'a, Gate>;
    /// BRANCHES merged in order into a scratch worktree of REPO.
    fn trial_merge<'a>(
        &'a self,
        repo: &'a Path,
        branches: &'a [String],
    ) -> GitFuture<'a, TrialResult>;
}

pub async fn propose(_: &Front, _: &Caller, _: ProposeParams) -> Result<JobSummary, Error> {
    Err(not_yet("job/propose", "16a"))
}

pub async fn start_task(_: &Front, _: &Caller, _: StartTaskParams) -> Result<JobSummary, Error> {
    Err(not_yet("job/start-task", "16a"))
}

pub async fn approve(_: &Front, _: &Caller, _: WithBudget) -> Result<JobSummary, Error> {
    Err(not_yet("job/approve", "16a"))
}

pub async fn order(_: &Front, _: &Caller, _: OrderParams) -> Result<JobSummary, Error> {
    Err(not_yet("job/order", "16a"))
}

pub async fn block(_: &Front, _: &Caller, _: BlockParams) -> Result<JobSummary, Error> {
    Err(not_yet("job/block", "16a"))
}

pub async fn unblock(_: &Front, _: &Caller, _: ByTask) -> Result<JobSummary, Error> {
    Err(not_yet("job/unblock", "16a"))
}

pub async fn stop(_: &Front, _: &Caller, _: ById) -> Result<JobSummary, Error> {
    Err(not_yet("job/stop", "16a"))
}

pub async fn status(_: &Front, _: &Caller, _: StatusParams) -> Result<JobStatusResult, Error> {
    Err(not_yet("job/status", "16a"))
}

pub async fn card(_: &Front, _: &Caller, _: CardParams) -> Result<JobSummary, Error> {
    Err(not_yet("job/card", "16b"))
}

pub async fn reply(_: &Front, _: &Caller, _: ReplyParams) -> Result<bool, Error> {
    Err(not_yet("job/reply", "16b"))
}

pub async fn dismiss(_: &Front, _: &Caller, _: ByMessage) -> Result<bool, Error> {
    Err(not_yet("job/dismiss", "16b"))
}

pub async fn reassign(_: &Front, _: &Caller, _: ReassignParams) -> Result<JobSummary, Error> {
    Err(not_yet("job/reassign", "16b"))
}

pub async fn resume(_: &Front, _: &Caller, _: WithBudget) -> Result<JobSummary, Error> {
    Err(not_yet("job/resume", "16b"))
}

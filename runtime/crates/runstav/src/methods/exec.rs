//! Jobs: long work an agent or the user starts (a build, tests, a loop, a container), run by the hub in the starter's
//! sandbox as a unit of its own (agent system part 1, Tasks 11, 11b, 15; `docs/guide/jobs.md`).  Plan runs keep
//! `job/*` ([`super::jobs`]); these are `exec/*`.  An agent starts and reads jobs through its tools (`job_*`), which
//! answer with these same shapes.

use super::{invalid, method};
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, Id, null_as_empty};
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// What a job runs, for its summary's parser; `container` runs an allowed image (Task 11b).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ExecKind {
    Cargo,
    Ert,
    Domr,
    Other,
    Container,
}

/// Where a job is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ExecStatus {
    Running,
    /// Ended by itself (any exit code).
    Done,
    /// Ended by `exec/stop` or `job_stop`.
    Stopped,
    /// Ended by its time box.
    TimedOut,
    /// Its unit or process was gone at a hub start and left no exit.
    Lost,
}

/// A job's end, as the wake and `exec/get` give it: at most 20 lines.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ExecSummary {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit: Option<i32>,
    /// The failing tests' names the parser found (cargo test, ERT, domr).
    #[serde(default, deserialize_with = "null_as_empty")]
    pub failing: Vec<String>,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub lines: Vec<String>,
    /// The whole log's path.
    pub log: String,
}

/// One job.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ExecRow {
    pub id: String,
    /// The session that started it; none: the user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    pub kind: ExecKind,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub argv: Vec<String>,
    pub cwd: String,
    /// A container job's image, by digest.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    pub status: ExecStatus,
    /// When it started and ended (seconds since the epoch).
    pub started: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended: Option<f64>,
    pub timebox_s: u64,
    /// The transient unit's name (Linux), or none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<ExecSummary>,
}

/// One argument: at most 4096 characters.
pub type Arg = Bounded<String, 4096>;

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StartParams {
    /// The command and its arguments (at most 256); never run through a shell by the hub.
    pub argv: Bounded<Vec<Arg>, 256>,
    /// The folder it runs in: the starter's worktree or a folder under it (the user's: any project folder).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<AbsPath>,
    /// Seconds before it is ended: 1 to 86400 (default 3600).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timebox_s: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<ExecKind>,
    /// A container job's image: a name on `agents-container-images` (kind container only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<Bounded<String, 256>>,
    /// The machine: only `local` in part 1 (any other is refused: Calls made 3).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<Id>,
}

/// `exec/start`'s answer (and `job_start`'s): the job's id and what the agent does now.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Started {
    pub id: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ById {
    pub id: Id,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct ListParams {
    /// Only the jobs this session started.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<Id>,
    /// Only running jobs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub running: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Jobs {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub jobs: Vec<ExecRow>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct LogParams {
    pub id: Id,
    /// The first line (0-based).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<u64>,
    /// At most 1000 lines (default 200).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub n: Option<u64>,
}

/// A slice of a job's log.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct LogSlice {
    pub id: String,
    pub from: u64,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub lines: Vec<String>,
    /// The line after the slice, when there is more.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<u64>,
    pub running: bool,
}

/// The `exec-done` event: a job ended.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ExecDone {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    pub status: ExecStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit: Option<i32>,
    pub summary: ExecSummary,
}

fn check_start(p: &StartParams) -> Result<(), Error> {
    if p.argv.is_empty() || p.argv[0].is_empty() {
        return Err(invalid("argv", "a command: argv's first item"));
    }
    if p.timebox_s.is_some_and(|t| !(1..=86_400).contains(&t)) {
        return Err(invalid("timebox_s", "a time box of 1 to 86400 seconds"));
    }
    match (p.kind, &p.image) {
        (Some(ExecKind::Container), None) => {
            Err(invalid("image", "a container job names an image"))
        }
        (k, Some(_)) if k != Some(ExecKind::Container) => {
            Err(invalid("image", "only a container job names an image"))
        }
        _ => Ok(()),
    }
}

fn check_log(p: &LogParams) -> Result<(), Error> {
    match p.n {
        Some(n) if !(1..=1000).contains(&n) => Err(invalid("n", "1 to 1000 lines")),
        _ => Ok(()),
    }
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "exec/start", ExecStart(StartParams) -> Started,
            classes: [User], writes: true, home: Front,
            doc: "a job the hub runs as a unit of its own (in a project folder; a container job from the allowed images only); local only",
            check: check_start,
        ),
        method!(
            "exec/get", ExecGet(ById) -> ExecRow,
            classes: [User], writes: false, home: Front,
            doc: "one job: its status and, once it ended, its summary",
        ),
        method!(
            "exec/list", ExecList(ListParams) -> Jobs,
            classes: [User], writes: false, home: Front,
            doc: "the jobs (a session's, or the running ones), newest first",
        ),
        method!(
            "exec/stop", ExecStop(ById) -> ExecRow,
            classes: [User], writes: true, home: Front,
            doc: "a running job ended (its unit stopped); its starter is woken as for any end",
        ),
        method!(
            "exec/log", ExecLog(LogParams) -> LogSlice,
            classes: [User], writes: false, home: Front,
            doc: "lines of a job's log (at most 1000 a call)",
            check: check_log,
        ),
    ]
}

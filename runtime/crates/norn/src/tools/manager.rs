//! The manager's tools (agent system part 1, Task 25; `docs/guide/agents.md`, "A manager agent"): on a manager
//! session's socket only, each through the hub's matrix with the manager's column.  `agent_start`'s grants only
//! narrow the manager's own; one level (no manager starts a manager); `transcript_slice` never returns a whole
//! transcript; `trial_merge` and `merge` touch integration branches only.

use mimir::Tool;
use runstav::methods::agents::{MoveParams, SliceParams};
use runstav::methods::graph::ParsedId;
use runstav::methods::matrix::{CellRow, Limit};
use runstav::methods::plans::ReportsParams;
use runstav::types::{Bounded, Id, Text};
use schemars::JsonSchema;
use serde::Deserialize;

use super::guard::CoordTool;
use super::guard::guarded;
use super::{Coord, Ctx, Identity};
use mimir::BoxFuture;
use runstav::methods::matrix::Role;

/// `agent_start`'s arguments: a worker on a profile, for a task, with grants (cells for the worker's column that
/// must not be wider than the manager's) and a budget out of the manager's own.
#[derive(Debug, Deserialize, serde::Serialize, JsonSchema)]
pub struct AgentStartArgs {
    #[serde(default)]
    pub task: Option<ParsedId>,
    /// Only `worker`: a manager does not start a manager (one level).
    #[serde(default)]
    pub role: Option<Role>,
    pub profile: Bounded<String, 128>,
    #[serde(default)]
    pub grants: Bounded<Vec<CellRow>, 64>,
    #[serde(default)]
    pub budget: Bounded<Vec<Limit>, 5>,
}

/// A session the manager started.
#[derive(Debug, Deserialize, serde::Serialize, JsonSchema)]
pub struct SessionArg {
    pub id: Id,
}

#[derive(Debug, Deserialize, serde::Serialize, JsonSchema)]
pub struct AgentMessageArgs {
    pub id: Id,
    pub text: Text,
}

#[derive(Debug, Deserialize, serde::Serialize, JsonSchema)]
pub struct TrialMergeArgs {
    /// Branches merged in order into a scratch worktree.
    pub branches: Bounded<Vec<Bounded<String, 256>>, 16>,
}

#[derive(Debug, Deserialize, serde::Serialize, JsonSchema)]
pub struct MergeArgs {
    /// A task's branch, merged `--no-ff` into the run's integration branch through the merge gate.
    pub branch: Bounded<String, 256>,
}

/// The session calling: only a session the hub runs has a manager's tools.
fn session(who: &Identity) -> Result<&str, String> {
    match who {
        Identity::Session { sid, .. } => Ok(sid),
        _ => Err("only a manager session the hub runs has these tools".into()),
    }
}

/// A manager tool: its arguments go to the hub as JSON, which checks the role, the matrix and the grants.
macro_rules! manager_tool {
    ($ty:ident, $name:literal, $args:ty, $doc:literal) => {
        pub struct $ty;

        impl CoordTool for $ty {
            type Args = $args;
            const NAME: &'static str = $name;
            const DESCRIPTION: &'static str = $doc;
            fn run<'a>(
                &'a self,
                coord: &'a Coord,
                who: &'a Identity,
                args: Self::Args,
            ) -> BoxFuture<'a, Result<String, String>> {
                Box::pin(async move {
                    let sid = session(who)?;
                    let v = serde_json::to_value(&args).map_err(|e| e.to_string())?;
                    coord.hub().manager(sid, $name, v).await
                })
            }
        }
    };
}

manager_tool!(
    AgentStart,
    "agent_start",
    AgentStartArgs,
    "Start a worker on a profile for a task, with grants no wider than yours and a budget out of yours."
);
manager_tool!(
    AgentMessage,
    "agent_message",
    AgentMessageArgs,
    "A message to a worker you started (text only: it never approves anything)."
);
manager_tool!(
    AgentPause,
    "agent_pause",
    SessionArg,
    "Pause a worker after its current tool call."
);
manager_tool!(
    AgentStop,
    "agent_stop",
    SessionArg,
    "Stop a worker you started."
);
manager_tool!(
    AgentMove,
    "agent_move",
    MoveParams,
    "Move a worker to another profile (same worktree, a summary handoff)."
);
manager_tool!(
    ReportRead,
    "report_read",
    ReportsParams,
    "A task's structured reports, or one by id."
);
manager_tool!(
    TranscriptSlice,
    "transcript_slice",
    SliceParams,
    "Steps of a worker's transcript with their entries (at most 50)."
);
manager_tool!(
    TrialMerge,
    "trial_merge",
    TrialMergeArgs,
    "Merge branches in order in a scratch worktree: clean, or the conflicting paths."
);
manager_tool!(
    Merge,
    "merge",
    MergeArgs,
    "Merge a worker's branch into your integration branch through the merge gate (never main)."
);

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![
        guarded(AgentStart),
        guarded(AgentMessage),
        guarded(AgentPause),
        guarded(AgentStop),
        guarded(AgentMove),
        guarded(ReportRead),
        guarded(TranscriptSlice),
        guarded(TrialMerge),
        guarded(Merge),
    ]
}

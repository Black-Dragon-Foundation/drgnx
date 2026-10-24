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

use super::guard::guarded;
use super::{Ctx, stub_tool};

/// `agent_start`'s arguments: a worker on a profile, for a task, with grants (cells for the worker's column that
/// must not be wider than the manager's) and a budget out of the manager's own.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct AgentStartArgs {
    #[serde(default)]
    pub task: Option<ParsedId>,
    pub profile: Bounded<String, 128>,
    #[serde(default)]
    pub grants: Bounded<Vec<CellRow>, 64>,
    #[serde(default)]
    pub budget: Bounded<Vec<Limit>, 5>,
}

/// A session the manager started.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct SessionArg {
    pub id: Id,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AgentMessageArgs {
    pub id: Id,
    pub text: Text,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct TrialMergeArgs {
    /// Branches merged in order into a scratch worktree.
    pub branches: Bounded<Vec<Bounded<String, 256>>, 16>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct MergeArgs {
    /// A task's branch, merged `--no-ff` into the run's integration branch through the merge gate.
    pub branch: Bounded<String, 256>,
}

stub_tool!(
    AgentStart,
    "agent_start",
    AgentStartArgs,
    "25",
    "Start a worker on a profile for a task, with grants no wider than yours and a budget out of yours."
);
stub_tool!(
    AgentMessage,
    "agent_message",
    AgentMessageArgs,
    "25",
    "A message to a worker you started (text only: it never approves anything)."
);
stub_tool!(
    AgentPause,
    "agent_pause",
    SessionArg,
    "25",
    "Pause a worker after its current tool call."
);
stub_tool!(
    AgentStop,
    "agent_stop",
    SessionArg,
    "25",
    "Stop a worker you started."
);
stub_tool!(
    AgentMove,
    "agent_move",
    MoveParams,
    "25",
    "Move a worker to another profile (same worktree, a summary handoff)."
);
stub_tool!(
    ReportRead,
    "report_read",
    ReportsParams,
    "25",
    "A task's structured reports, or one by id."
);
stub_tool!(
    TranscriptSlice,
    "transcript_slice",
    SliceParams,
    "25",
    "Steps of a worker's transcript with their entries (at most 50)."
);
stub_tool!(
    TrialMerge,
    "trial_merge",
    TrialMergeArgs,
    "25",
    "Merge branches in order in a scratch worktree: clean, or the conflicting paths."
);
stub_tool!(
    Merge,
    "merge",
    MergeArgs,
    "25",
    "Merge a task's branch into the run's integration branch through the merge gate."
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

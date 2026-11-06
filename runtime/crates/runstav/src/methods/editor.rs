//! Agents in the editor (docs/develop/hub.md, "The follow feed").
//!
//! The follow feed: `agents/follow {view, session}` and `agents/unfollow {view}` (the user's), per (connection, view);
//! the event `agent-follow` goes to that connection only.  At most one move per 200 ms; a read's switch to another
//! file waits for a 500 ms dwell; a search or glob never switches files (its query goes in the line); an edit or a
//! pending edit switches at once.  Nothing is generated: the line is the agent's own step title or plan entry.

use super::method;
use crate::registry::Method;
use crate::types::{Bounded, Id};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `agents/follow`: the editor's VIEW (a follow window) follows SESSION from now on; a view follows one session.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct FollowParams {
    pub view: Bounded<String, 128>,
    pub session: Id,
}

/// `agents/unfollow`: VIEW follows nothing any more.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct UnfollowParams {
    pub view: Bounded<String, 128>,
}

/// What the agent is doing where the follow window shows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum FollowMode {
    /// A search or a glob: the files it lists (it never moves the window to one).
    Listed,
    Read,
    /// An edit about to land (a permission request, or an edit call still pending).
    Pending,
    Write,
    Edit,
}

/// Which of the agent's own words the line shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum WhySource {
    /// The agent's `in_progress` plan entry.
    PlanEntry,
    /// The tool call's title.
    StepTitle,
}

/// `agent-follow`: where the session VIEW follows is now.  `file` in `worktree` (the session's folder), at `line` and
/// `col` (1-based; none: the file only); `changed`: the file changed on disk since the last move, so the window
/// refreshes it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AgentFollow {
    pub view: String,
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    pub worktree: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub col: Option<u32>,
    pub mode: FollowMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_entry: Option<String>,
    pub why_source: WhySource,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changed: Option<bool>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "agents/follow", AgentsFollow(FollowParams) -> bool,
            classes: [User], writes: false,
            doc: "this connection's view follows a session: agent-follow events to it alone (at most one move per 200 ms; a read's file switch after a 500 ms dwell; a search never switches; an edit at once), the session's latest place first",
        ),
        method!(
            "agents/unfollow", AgentsUnfollow(UnfollowParams) -> bool,
            classes: [User], writes: false,
            doc: "this connection's view follows nothing any more (true when it followed a session)",
        ),
    ]
}

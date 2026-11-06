//! Say it (docs/develop/hub.md, "Say it"): one prompt becomes a proposed plan.  A planning chat in a scratch folder,
//! with no repository and no graph, answers with a fenced `drgnx-proposal` block; the hub checks it and proposes the
//! job, which waits for the user's OK like any proposal.  The repository is the caller's, never the agent's.

use super::method;
use crate::registry::Method;
use crate::types::{AbsPath, Bounded, Id, Text};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// What the user wants done, and where.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SayStart {
    /// The user's words.
    pub text: Text,
    /// The repository the job runs in.
    pub repo: AbsPath,
    /// The project the plan is filed under.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<Id>,
    /// The profile that plans (none: the `say` route, else the first `implement` route's).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<Bounded<String, 128>>,
}

/// The user's change to a planning session's proposal.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SayRevise {
    /// The planning session.
    pub id: Id,
    pub text: Text,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
pub struct SayById {
    /// The planning session.
    pub id: Id,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SayStarted {
    /// The planning session.
    pub id: String,
}

/// `say-proposal`: the planning session's proposal is job JOB, waiting for the user's OK unless it started.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SayProposal {
    pub id: String,
    pub job: String,
    /// Started at once by the Autonomous preset within its cells: nothing waits for an OK.
    pub started: bool,
}

/// `say-message`: the planning agent asks the user something (its words, agent-written).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SayMessage {
    pub id: String,
    pub text: String,
}

/// `say-failed`: the planning gave up, and why.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SayFailed {
    pub id: String,
    pub why: String,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "say/start", SayStart(SayStart) -> SayStarted,
            classes: [User], writes: true,
            doc: "one prompt becomes a proposed plan: a planning chat with no repository answers with a drgnx-proposal block, which the hub checks and proposes (say-proposal, say-message, say-failed)",
        ),
        method!(
            "say/revise", SayRevise(SayRevise) -> bool,
            classes: [User], writes: true,
            doc: "the user's change: the standing proposal is stopped and the planning session asked again",
        ),
        method!(
            "say/end", SayEnd(SayById) -> bool,
            classes: [User], writes: true,
            doc: "the planning session is stopped and forgotten (its proposal, a job, stays)",
        ),
    ]
}

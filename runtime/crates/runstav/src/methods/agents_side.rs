//! The Agents side (`agents/side/*`): one card per session, hub-built rows (docs/develop/work-space.md, "The Agents
//! side"): needs you first, then running, then the rest by last activity, with the five newest past sessions of Claude
//! Code, Gemini CLI and Codex under "Earlier".

use super::method;
use super::view::check_ids;
use crate::registry::Method;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `agents/side/subscribe`: VIEW shows the Agents side; its rows come as `view-patch` per display class and follow
/// every session's change.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Subscribe {
    pub view: String,
}

/// `agents/side/set`: a change to VIEW: REFRESH reads the sessions and the past sessions again.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Set {
    pub view: String,
    #[serde(default)]
    pub refresh: bool,
}

/// A view id: `agents/side/close`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewId {
    pub view: String,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "agents/side/subscribe", AgentsSideSubscribe(Subscribe) -> bool,
            classes: [User], writes: false,
            doc: "a hub-fed view shows the Agents side: a card per session (needs you first, then running, then the rest by last activity), each with one button, and the five newest past sessions under Earlier; one session's change patches only its card's rows",
            check: |p: &Subscribe| check_ids(&p.view, None),
        ),
        method!(
            "agents/side/set", AgentsSideSet(Set) -> bool,
            classes: [User], writes: false,
            doc: "a change to an Agents side view: refresh reads the sessions and the past sessions again",
            check: |p: &Set| check_ids(&p.view, None),
        ),
        method!(
            "agents/side/close", AgentsSideClose(ViewId) -> bool,
            classes: [User], writes: false,
            doc: "an Agents side view is shown no more",
            check: |p: &ViewId| check_ids(&p.view, None),
        ),
    ]
}

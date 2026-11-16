//! The Changes view (`changes/*`): what the agents changed, grouped by the task each worked on (task, file, hunk),
//! as hub-built rows (docs/develop/work-space.md, "Changes by task").

use super::method;
use super::view::check_ids;
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `changes/subscribe`: VIEW shows what the agents changed, by task; its rows come as `view-patch` per display class.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Subscribe {
    pub view: String,
}

/// `changes/set`: a change to VIEW: REFRESH reads the sessions' edits again.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Set {
    pub view: String,
    #[serde(default)]
    pub refresh: bool,
}

/// A view id: `changes/close`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewId {
    pub view: String,
}

fn check_view(view: &str) -> Result<(), Error> {
    check_ids(view, None)
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "changes/subscribe", ChangesSubscribe(Subscribe) -> bool,
            classes: [User], writes: false,
            doc: "a hub-fed view shows what the agents changed, grouped by the task each worked on (task, file, hunk; the hunks no task owns last), as rows",
            check: |p: &Subscribe| check_view(&p.view),
        ),
        method!(
            "changes/set", ChangesSet(Set) -> bool,
            classes: [User], writes: false,
            doc: "a change to a Changes view: refresh reads the sessions' edits again",
            check: |p: &Set| check_view(&p.view),
        ),
        method!(
            "changes/close", ChangesClose(ViewId) -> bool,
            classes: [User], writes: false,
            doc: "a Changes view is shown no more",
            check: |p: &ViewId| check_view(&p.view),
        ),
    ]
}

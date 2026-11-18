//! The review screen (`review-screen/*`): one screen for a change under review, code or document, as hub-built rows
//! (docs/develop/work-space.md, "The review screen"): what changed, the effect on tasks, the reason of each change,
//! then the actions.

use super::method;
use super::view::check_ids;
use crate::registry::Method;
use crate::wire::Error;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `review-screen/subscribe`: VIEW shows one change under review. Exactly one of `session` (the code an agent's
/// session changed against its branch's base) and `doc` (a spec or plan, against its text at `from`, a git blob id;
/// without `from`, against the document as the last commit has it).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Subscribe {
    pub view: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub doc: Option<std::path::PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
}

/// `review-screen/set`: a change to VIEW: REFRESH reads the change and its effects again.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Set {
    pub view: String,
    #[serde(default)]
    pub refresh: bool,
}

/// A view id: `review-screen/close`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewId {
    pub view: String,
}

fn check_subscribe(p: &Subscribe) -> Result<(), Error> {
    check_ids(&p.view, None)?;
    match (&p.session, &p.doc) {
        (Some(_), None) | (None, Some(_)) => Ok(()),
        _ => Err(Error {
            code: crate::wire::ErrorCode::InvalidParams,
            message: "exactly one of `session` and `doc`".into(),
            path: Some("session".into()),
        }),
    }
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "review-screen/subscribe", ReviewScreenSubscribe(Subscribe) -> bool,
            classes: [User], writes: false,
            doc: "a hub-fed view shows one change under review (an agent session's code, or a document against its last reviewed text): what changed, the effect on tasks, the reason of each change, then the actions, as rows",
            check: check_subscribe,
        ),
        method!(
            "review-screen/set", ReviewScreenSet(Set) -> bool,
            classes: [User], writes: false,
            doc: "a change to a review screen: refresh reads the change and its effects again",
            check: |p: &Set| check_ids(&p.view, None),
        ),
        method!(
            "review-screen/close", ReviewScreenClose(ViewId) -> bool,
            classes: [User], writes: false,
            doc: "a review screen is shown no more",
            check: |p: &ViewId| check_ids(&p.view, None),
        ),
    ]
}

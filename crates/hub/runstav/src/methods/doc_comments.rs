//! The comment threads of a document (`doc-comments/*`): the right side of a spec or plan being written, a card for
//! each thread with its replies, as hub-built rows (docs/develop/work-space.md, "Comments on a paragraph").

use super::method;
use super::view::check_ids;
use crate::registry::Method;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `doc-comments/subscribe`: VIEW shows the threads of RECORD (`spec:ID`, `plan:ID`, `decision:N` or `task:ID`).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Subscribe {
    pub view: String,
    pub record: String,
}

/// `doc-comments/set`: REFRESH reads the threads again (after a comment, a reply or an agent's answer).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Set {
    pub view: String,
    #[serde(default)]
    pub refresh: bool,
}

/// A view id: `doc-comments/close`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewId {
    pub view: String,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "doc-comments/subscribe", DocCommentsSubscribe(Subscribe) -> bool,
            classes: [User], writes: false,
            doc: "a hub-fed view shows the comment threads of a record: a card for each thread (the paragraph quoted, the comment, its replies, whom it was sent to or that no agent is writing it), as rows",
            check: |p: &Subscribe| check_ids(&p.view, None),
        ),
        method!(
            "doc-comments/set", DocCommentsSet(Set) -> bool,
            classes: [User], writes: false,
            doc: "a change to a comment-threads view: refresh reads the threads again",
            check: |p: &Set| check_ids(&p.view, None),
        ),
        method!(
            "doc-comments/close", DocCommentsClose(ViewId) -> bool,
            classes: [User], writes: false,
            doc: "a comment-threads view is shown no more",
            check: |p: &ViewId| check_ids(&p.view, None),
        ),
    ]
}

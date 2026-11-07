//! Git letters for the views (`git/letters`; docs/develop/hub.md, "Rows"): a repository's status as rows, sent to a
//! hub-fed view the way every row stream is.

use super::method;
use crate::registry::Method;
use crate::types::AbsPath;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `git/letters`: read ROOT's git status and give VIEW its rows (the event `view-patch`): `f:<path>` per changed
/// path (a letter in its git face), `d:<folder>` per folder in SHOWN that holds a change (and the repository's own,
/// `.`), and `branch`. A later call patches only what changed.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct LettersParams {
    /// The hub-fed view that shows the rows (`view/env`).
    pub view: String,
    pub root: AbsPath,
    /// The folders the view shows (relative to the root); no other folder gets a row.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shown: Option<Vec<String>>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![method!(
        "git/letters", GitLetters(LettersParams) -> bool,
        classes: [User], writes: false,
        doc: "read a repository's git status on a thread and give a hub-fed view its rows (a letter per changed path, a mark per shown folder with a change, the branch): the view-patch follows, only what changed after the first",
    )]
}

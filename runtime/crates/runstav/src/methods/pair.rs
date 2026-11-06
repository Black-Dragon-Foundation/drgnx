//! Pair mode's wire (docs/guide/pair-mode.md, docs/develop/hub.md "Pair mode"): a paired chat's writes go through
//! the hub's door to the editor that has the file open.  The hub sends `pair-apply` (a write, with a time to live the
//! editor counts from its arrival), `pair-read` (the buffer's text, unsaved edits included) and `pair-reconcile`
//! (what became of a write whose answer did not come); the editor answers with `pair/answer` and `pair/read-answer`.
//! The hub's verdict on a write is only ever the editor's answer.

use super::method;
use crate::registry::Method;
use crate::types::{AbsPath, Text};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// One edit of a write, as the editor applies it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum Edit {
    /// `old` must match exactly once in the buffer's text when the editor applies it; it becomes `new`.
    Replace { old: String, new: String },
    /// Lines `line ..< line + delete` (1-based) of the text read at the write's `version` become `text`.
    Lines {
        line: u64,
        delete: u64,
        text: String,
    },
}

/// `pair-apply`: write WRITE of session SESSION to FILE, to the editor that has it open.  `version` is the buffer's
/// change counter the edits are based on (none: `edit_file`, or a new file), `floor` the oldest version the hub
/// still holds for a read of this file (the editor keeps its change log back to it), `ttl_ms` how long the write
/// may wait in the editor's queue, counted from its arrival.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PairApply {
    pub write: u64,
    pub session: String,
    /// The writes to FILE in the order the hub sends them (1, 2, …).
    pub ordinal: u64,
    pub file: AbsPath,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub floor: Option<u64>,
    pub edits: Vec<Edit>,
    pub ttl_ms: u64,
}

/// `pair-read`: the editor's text of FILE, answered by `pair/read-answer` with the same REQ.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PairRead {
    pub req: u64,
    pub file: AbsPath,
}

/// `pair-reconcile`: write WRITE's answer did not come in its time to live; the editor answers `pair/answer` from
/// what it applied (by write id and buffer hash).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PairReconcile {
    pub write: u64,
    pub file: AbsPath,
}

/// What became of a write in the editor.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum PairResult {
    /// Applied whole.
    Applied,
    /// Refused whole: `reason` says why (`lines` the user's lines it would have touched).
    Refused,
    /// Dropped unapplied: its time to live ran out in the queue, or the door closed while it waited.
    Dropped,
}

/// `pair/answer` (the editor): write WRITE's end.  An applied write gives the buffer's `version` after it and whether
/// it was saved (`saved`: true for a clean buffer saved, false for one the user's unsaved edits keep unsaved;
/// `not_saved`: the save would have asked, or failed, and why).  A refusal names `reason` (`overlap`, `guard`,
/// `no-match`, `several`, `gap`, `read-only`, `changed-on-disk`, `locked`, or the editor's own words) and the user's
/// `lines` it would have touched.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PairAnswer {
    pub write: u64,
    pub result: PairResult,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<Text>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lines: Option<[u64; 2]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub saved: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub not_saved: Option<Text>,
}

/// `pair/read-answer` (the editor): REQ's text and the buffer's version, or why the editor cannot give it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PairReadAnswer {
    pub req: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<Text>,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "pair/answer", PairAnswer(PairAnswer) -> bool,
            classes: [User], writes: false,
            doc: "the editor's answer to a pair-apply or pair-reconcile: applied (version, saved), refused (reason, lines) or dropped; true when the hub was waiting for it",
        ),
        method!(
            "pair/read-answer", PairReadAnswer(PairReadAnswer) -> bool,
            classes: [User], writes: false,
            doc: "the editor's answer to a pair-read: the buffer's text and version, or why not; true when the hub was waiting for it",
        ),
    ]
}

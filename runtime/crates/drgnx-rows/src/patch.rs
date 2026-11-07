//! A patch: one (view, display class) from version `base` to `version`.

use crate::row::{ImageId, Row};
use serde::{Deserialize, Serialize};

/// One operation of a patch, applied in order.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Op {
    /// The view is exactly these rows.
    Reset(Vec<Row>),
    /// ROWS go after the row keyed AFTER (none: at the top).
    Insert {
        after: Option<String>,
        rows: Vec<Row>,
    },
    /// Each row replaces the row of its key.
    Replace(Vec<Row>),
    /// The rows of these keys go.
    Remove(Vec<String>),
}

/// What changed in one (view, class).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Patch {
    pub view: String,
    pub class: String,
    /// The hub's instance id, drawn at its start: Lisp drops a patch whose `hub` is not its last reset's.
    pub hub: u64,
    /// The version this patch applies to (0 on a reset).
    pub base: u64,
    pub version: u64,
    /// The env epoch the rows were built for (Lisp's number, echoed).
    pub env_epoch: u64,
    pub ops: Vec<Op>,
    /// `[id, svg]`: images the rows name and Lisp may not hold yet (a reset: every image its rows name).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<(ImageId, String)>,
}

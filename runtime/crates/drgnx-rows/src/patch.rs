//! A patch: one (view, display class) from version `base` to `version`.

use crate::row::{ImageId, Row};
use crate::style::{Style, StyleId, TermMeta};
use serde::{Deserialize, Serialize};

/// One operation of a patch, applied in order.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
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
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
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
    /// `[id, style]`: the styles the rows' `s:<id>` runs name and Lisp may not hold yet (a terminal view's).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub styles: Vec<(StyleId, Style)>,
    /// A terminal view's cursor, screen and title, when they changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term: Option<TermMeta>,
}

/// The ops that turn OLD into NEW, rows matched by key: removes, then replaces of changed rows, then inserts of new
/// ones after the row before them. A reset when the rows kept changed their order (a move is not an op). Empty when
/// nothing changed.
pub fn diff(old: &[Row], new: &[Row]) -> Vec<Op> {
    use std::collections::HashMap;
    let was: HashMap<&str, &Row> = old.iter().map(|r| (r.key.as_str(), r)).collect();
    let now: HashMap<&str, ()> = new.iter().map(|r| (r.key.as_str(), ())).collect();
    let kept_old: Vec<&str> = old
        .iter()
        .map(|r| r.key.as_str())
        .filter(|k| now.contains_key(k))
        .collect();
    let kept_new: Vec<&str> = new
        .iter()
        .map(|r| r.key.as_str())
        .filter(|k| was.contains_key(k))
        .collect();
    if kept_old != kept_new {
        return vec![Op::Reset(new.to_vec())];
    }
    let mut ops = Vec::new();
    let gone: Vec<String> = old
        .iter()
        .filter(|r| !now.contains_key(r.key.as_str()))
        .map(|r| r.key.clone())
        .collect();
    if !gone.is_empty() {
        ops.push(Op::Remove(gone));
    }
    let changed: Vec<Row> = new
        .iter()
        .filter(|r| was.get(r.key.as_str()).is_some_and(|o| *o != *r))
        .cloned()
        .collect();
    if !changed.is_empty() {
        ops.push(Op::Replace(changed));
    }
    // each run of new rows goes after the row before it (none: the top)
    let mut i = 0;
    while i < new.len() {
        if was.contains_key(new[i].key.as_str()) {
            i += 1;
            continue;
        }
        let after = i.checked_sub(1).map(|j| new[j].key.clone());
        let start = i;
        while i < new.len() && !was.contains_key(new[i].key.as_str()) {
            i += 1;
        }
        ops.push(Op::Insert {
            after,
            rows: new[start..i].to_vec(),
        });
    }
    ops
}

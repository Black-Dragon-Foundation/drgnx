//! How a point run's records decide a step under the matrix (OD3): narrowing only.

use serde_json::Value;

use super::{Record, Verdict};
use crate::matrix::{Cell, Verdict as MatrixVerdict};

/// At most this many notes per step; one more line says how many were left out.
pub const MAX_ANNOTATIONS: usize = 8;
/// Each note is cut to this many bytes (at a character boundary).
pub const MAX_ANNOTATION_BYTES: usize = 2048;

#[derive(Debug, Clone, PartialEq)]
pub enum Decision {
    /// Go on, with the last accepted change's replacement object, if any.
    Proceed {
        changed: Option<Value>,
    },
    /// The matrix asks, as without hooks; a change still applies to what is asked about.
    Ask {
        changed: Option<Value>,
    },
    Deny(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    pub decision: Decision,
    /// The deciding record's index in `provenance`: the deny's. `None` when the matrix itself refused.
    pub decided_by: Option<usize>,
    pub annotations: Vec<String>,
    pub provenance: Vec<Record>,
}

/// Combines RECORDS (in run order) under CELL (`None` at a hub tool whose matrix checks are in its body: Allow).
/// ACCEPTS_CHANGE is whether this point may change what runs.
///
/// - Never stays a deny; Ask stays Ask and Allow stays Allow unless a record denies. `allow` is "no objection".
/// - The first deny decides. A failure (`error`) of a non-advisory hook is a deny with its text, and of an advisory
///   one a note.
/// - A change where none is accepted is a failure ("change is not accepted here"). Otherwise the last change wins:
///   each hook already saw the one before ([`super::run`]).
/// - Notes add up: at most [`MAX_ANNOTATIONS`], each cut to [`MAX_ANNOTATION_BYTES`], then "+N more".
pub fn combine(cell: Option<Cell>, accepts_change: bool, records: &[Record]) -> Outcome {
    let mut deny: Option<(String, Option<usize>)> = None;
    if cell.is_some_and(|c| c.verdict == MatrixVerdict::Never) {
        deny = Some(("the permissions matrix refuses this step".into(), None));
    }
    let mut changed = None;
    let mut notes = Vec::new();
    for (i, r) in records.iter().enumerate() {
        let failure = match (&r.verdict, &r.error) {
            (_, Some(text)) => Some(text.clone()),
            (None, None) | (Some(Verdict::Allow), None) => None,
            (Some(Verdict::Deny(reason)), None) => {
                if deny.is_none() {
                    deny = Some((reason.clone(), Some(i)));
                }
                None
            }
            (Some(Verdict::Annotate(text)), None) => {
                notes.push(text.clone());
                None
            }
            (Some(Verdict::Change(v)), None) => {
                if accepts_change {
                    changed = Some(v.clone());
                    None
                } else {
                    Some(format!(
                        "hook {} failed: change is not accepted here",
                        r.source.name()
                    ))
                }
            }
        };
        if let Some(text) = failure {
            if r.advisory {
                notes.push(text);
            } else if deny.is_none() {
                deny = Some((text, Some(i)));
            }
        }
    }
    let (decision, decided_by) = match deny {
        Some((reason, by)) => (Decision::Deny(reason), by),
        None if cell.is_some_and(|c| c.verdict == MatrixVerdict::Ask) => {
            (Decision::Ask { changed }, None)
        }
        None => (Decision::Proceed { changed }, None),
    };
    Outcome {
        decision,
        decided_by,
        annotations: capped(notes),
        provenance: records.to_vec(),
    }
}

/// NOTES capped in number and size.
fn capped(mut notes: Vec<String>) -> Vec<String> {
    let more = notes.len().saturating_sub(MAX_ANNOTATIONS);
    notes.truncate(MAX_ANNOTATIONS);
    for n in &mut notes {
        if n.len() > MAX_ANNOTATION_BYTES {
            let mut end = MAX_ANNOTATION_BYTES;
            while !n.is_char_boundary(end) {
                end -= 1;
            }
            n.truncate(end);
        }
    }
    if more > 0 {
        notes.push(format!("+{more} more"));
    }
    notes
}

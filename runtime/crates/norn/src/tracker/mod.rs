//! The tracker (Task 13; storage §6.3, answers 2 and 4, calls 5, 6, 16, 17): agents create and change tasks in their
//! project — optimistic versions, fenced leases, splits, links without cycles, labels by add and remove, user-made
//! tasks behind the user's grant — and the agents affected get notices.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 13 removes this line.

pub mod notices;
pub mod ops;

use serde::{Deserialize, Serialize};
use urdr::Connection;
use urdr::graph::entity::{Ent, FieldChange};
use urdr::graph::{Tx, WriteError};

use crate::scope::{Caller, StoreScope};

/// A link op's kind (a `norn::kinds::LINKS` name).
pub type LinkName = String;

/// One tracker operation (`task_write`'s ops; `tasks/write`).
#[derive(Clone, Debug, PartialEq)]
pub enum TaskOp {
    Create {
        title: String,
        body: Option<String>,
        priority: Option<i64>,
        labels: Vec<String>,
        acceptance: Option<String>,
        parent: Option<String>,
    },
    Update {
        id: String,
        ver: i64,
        title: Option<String>,
        body: Option<String>,
        priority: Option<i64>,
        acceptance: Option<String>,
        status: Option<String>,
    },
    Claim {
        id: String,
    },
    Heartbeat {
        id: String,
        lease: i64,
    },
    Release {
        id: String,
        lease: i64,
        note: Option<String>,
    },
    Handoff {
        id: String,
        lease: i64,
        to: Option<String>,
        note: String,
    },
    Reassign {
        id: String,
        ver: i64,
        to: Option<String>,
        note: String,
    },
    Split {
        id: String,
        ver: i64,
        parts: Vec<String>,
        /// `children` (default) or `replace`.
        mode: Option<String>,
    },
    Complete {
        id: String,
        lease: i64,
        note: Option<String>,
    },
    Link {
        src: String,
        kind: LinkName,
        dst: String,
    },
    Unlink {
        src: String,
        kind: LinkName,
        dst: String,
    },
    Label {
        id: String,
        add: Vec<String>,
        remove: Vec<String>,
    },
    /// User class only: set or clear `data.tracker_tools`.
    Tools {
        id: String,
        tracker: Option<bool>,
    },
}

/// How a lease was lost.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LostHow {
    Expired,
    Reassign,
    Reclaimed,
}

/// What an op answers (a refusal is `Err(WriteError::Refused)` with what to do next).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskAnswer {
    Done {
        id: String,
        title: String,
        ver: i64,
        lease: Option<i64>,
    },
    Conflict {
        id: String,
        ver: i64,
        changed_since: Vec<FieldChange>,
        next: String,
    },
    LeaseLost {
        by: Option<String>,
        how: LostHow,
        tx: i64,
        note: Option<String>,
        next: String,
    },
    /// "Only I close my tasks": a close card instead of `done`.
    Proposed {
        card: i64,
    },
}

/// Run OP for CALLER in TX: one tx and one `event`, plus the notices it raises.
pub fn op(tx: &mut Tx<'_>, caller: &Caller, op: TaskOp) -> Result<TaskAnswer, WriteError> {
    todo!("Task 13")
}

/// The ready tasks in SCOPE with all of LABELS (computed over `link_in`, never stored).
pub fn ready(
    conn: &Connection,
    scope: &StoreScope,
    labels: &[String],
    limit: u32,
) -> Result<Vec<Ent>, urdr::SqliteError> {
    todo!("Task 13")
}

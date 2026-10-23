//! Grants (Task 10; storage §5.5, §12.2 answers 1–2): only the user writes them, checked in urdr's write path
//! ([`register`] puts norn's rules into the [`Guard`]: kind `grant` and `kv` keys `setting:*` need `Class::User`).
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 10 removes this line.

use urdr::Connection;
use urdr::graph::guard::Guard;
use urdr::graph::{Tx, WriteError};

use crate::scope::Caller;

/// Who a grant is for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Who {
    /// A project's entity `n`.
    Project(i64),
    Profile(String),
    Session(String),
}

/// What it opens.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum What {
    Project(i64),
    All,
    /// For `EditUserTasks`: one task's `n`.
    Task(i64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    Read,
    EditUserTasks,
}

/// A grant entity.
#[derive(Clone, Debug, PartialEq)]
pub struct Grant {
    pub n: i64,
    pub id: String,
    pub who: Who,
    pub what: What,
    pub access: Access,
    pub expires: Option<f64>,
    /// `active` or `revoked`.
    pub status: String,
}

/// Which grants [`list`] answers.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Filter {
    pub who: Option<Who>,
    pub active: Option<bool>,
}

/// Put norn's class rules into GUARD.
pub fn register(guard: &mut Guard) {
    todo!("Task 10")
}

/// A new grant (the guard refuses it from any class but `User`).
pub fn create(
    tx: &mut Tx<'_>,
    who: Who,
    what: What,
    access: Access,
    expires: Option<f64>,
) -> Result<Grant, WriteError> {
    todo!("Task 10")
}

/// Set grant ID `revoked`; false when there was no active one.
pub fn revoke(tx: &mut Tx<'_>, id: &str) -> Result<bool, WriteError> {
    todo!("Task 10")
}

/// The grants CALLER may see that match FILTER (an agent or ext caller: only grants whose `who` is its own).
pub fn list(
    conn: &Connection,
    caller: &Caller,
    filter: &Filter,
    now: f64,
) -> Result<Vec<Grant>, urdr::SqliteError> {
    todo!("Task 10")
}

/// Whether CALLER holds an active `edit-user-tasks` grant for TASK (an entity `n`).
pub fn may_edit_user_task(
    conn: &Connection,
    caller: &Caller,
    task: i64,
    now: f64,
) -> Result<bool, urdr::SqliteError> {
    todo!("Task 10")
}

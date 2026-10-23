//! Who reads what (Task 10, Opus: the scope's root of trust; storage §5.5). The class and the project come from the
//! connection's identity, never from an argument; an agent's scope is its project plus the user's active grants,
//! computed per call.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 10 removes this line.

use urdr::Connection;
use urdr::graph::Class;
use urdr::graph::walk::{Scope, Seen};

use crate::project::ProjectCache;
use crate::tools::Identity;

/// The caller of a store operation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caller {
    pub class: Class,
    /// The `tx.actor` it writes as.
    pub actor: String,
    pub session: Option<String>,
    pub profile: Option<String>,
    pub job: Option<String>,
    /// The entity `n` of its project.
    pub project: Option<i64>,
    /// The Lisp backend's connection (`Caller.backend` of the dispatcher).
    pub backend: bool,
}

impl Caller {
    /// From a tool connection's identity (`Session { sid, profile, home }`, `Outside.home`, a job's repository), the
    /// project through CACHE.
    pub fn from_identity(identity: &Identity, cache: &ProjectCache) -> Caller {
        todo!("Task 10")
    }
}

/// A caller's scope at one moment.
#[derive(Clone, Debug)]
pub struct StoreScope {
    /// `None`: everything (user class).
    projects: Option<Vec<i64>>,
    /// The grant rows' max `updated_tx` when computed.
    grants_tx: i64,
}

impl Scope for StoreScope {
    fn allows(&self, project: Option<i64>) -> Seen {
        todo!("Task 10")
    }

    fn valid(&self) -> bool {
        todo!("Task 10")
    }
}

/// CALLER's scope now: user class everything; agent and ext their project plus active grants.
pub fn for_caller(
    conn: &Connection,
    caller: &Caller,
    now: f64,
) -> Result<StoreScope, urdr::SqliteError> {
    todo!("Task 10")
}

//! Graph walks in Rust (Task 4; storage §6.2): breadth first with batched lookups, bidirectional paths, budgets
//! enforced inside SQLite, hot nodes, and the caller's scope checked per level.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 4 removes this line.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::link::Direction;
use super::pool::ReadPool;

/// How a node's project is shown to the caller.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Seen {
    Full,
    /// Only `id`, `kind` and `title` (entities without a project, e.g. `agent:`).
    Stub,
    /// Not followed; counted in `hidden`, never named.
    Hidden,
}

/// The caller's scope (norn's `StoreScope`).
pub trait Scope: Send + Sync {
    fn allows(&self, project: Option<i64>) -> Seen;
    /// Re-checked before each level: false stops the walk (`truncated: scope`).
    fn valid(&self) -> bool;
}

/// A walk's budget.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    pub visits: u32,
    /// Enforced inside SQLite by the progress handler.
    pub deadline: Duration,
    /// The most nodes an answer carries.
    pub cap: u32,
    /// A node with more links than this is answered `hot`, not expanded.
    pub hot_degree: u32,
}

impl Default for Budget {
    fn default() -> Self {
        Budget {
            visits: 20_000,
            deadline: Duration::from_millis(250),
            cap: 200,
            hot_degree: 1_000,
        }
    }
}

/// A neighbors query.
#[derive(Clone, Debug, PartialEq)]
pub struct Walk {
    pub from: i64,
    /// Required past depth 3.
    pub kinds: Vec<String>,
    pub direction: Direction,
    pub depth: u32,
    /// A tx bound for an as-of walk.
    pub as_of: Option<i64>,
}

/// A path query.
#[derive(Clone, Debug, PartialEq)]
pub struct PathQ {
    pub from: i64,
    pub to: i64,
    pub kinds: Vec<String>,
    pub max_depth: u32,
    pub as_of: Option<i64>,
}

/// A node of an answer (`Seen::Full` or `Seen::Stub`; a stub carries no project).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Node {
    pub n: i64,
    pub id: String,
    pub kind: String,
    pub title: Option<String>,
    pub project: Option<i64>,
    pub seen: Seen,
    pub depth: u32,
    /// The degree of a hot node, which was not expanded.
    pub hot: Option<u64>,
}

/// A link of an answer.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Edge {
    pub src: i64,
    pub kind: String,
    pub dst: i64,
}

/// Why a walk stopped early.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Truncated {
    Budget,
    Deadline,
    Depth,
    Cap,
    Scope,
}

/// What a walk found.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WalkOut {
    pub nodes: Vec<Node>,
    pub links: Vec<Edge>,
    pub hidden: u32,
    pub truncated: Option<Truncated>,
}

/// Why a walk was not run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WalkError {
    /// E.g. "name kinds for depth over 3".
    Refused(String),
    Sql(String),
}

/// Breadth first from `walk.from`, one pool connection per level.
pub async fn neighbors(
    pool: &ReadPool,
    walk: Walk,
    scope: &dyn Scope,
    budget: Budget,
) -> Result<WalkOut, WalkError> {
    todo!("Task 4")
}

/// A shortest path, expanding the smaller frontier until they meet.
pub async fn path(
    pool: &ReadPool,
    q: PathQ,
    scope: &dyn Scope,
    budget: Budget,
) -> Result<WalkOut, WalkError> {
    todo!("Task 4")
}

//! Projects (Task 10; storage §5.3): `project:<root commit, 12 hex>`, taken once and kept; worktrees share their
//! repository's; slugs as `project_alias` rows. The git reads are the hardened ones of `hello` (`draugr::git` with
//! `Place::Trusted { read_only: true }`, a minimal environment, 3 s), run outside any write transaction.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 10 removes this line.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use urdr::graph::{Tx, WriteError};

/// A repository as git shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectRef {
    /// `project:<12 hex>`, or `project:x-<8 base36>` before the first commit.
    pub id: String,
    /// The git top-level (a worktree's main repository's for worktrees).
    pub root: PathBuf,
    /// The folder name (an alias).
    pub slug: String,
    pub root_commit: Option<String>,
}

/// The git top-level of CWD and its project; `None` outside a repository. Blocking (runs git): not on an async
/// worker, never under the writer's lock.
pub fn resolve(cwd: &Path) -> Option<ProjectRef> {
    todo!("Task 10")
}

/// The `project` entity of ROOT (made with its aliases when new; a new slug adds an alias): its `n`.
pub fn register(tx: &mut Tx<'_>, root: &ProjectRef) -> Result<i64, WriteError> {
    todo!("Task 10")
}

/// Folders resolved to projects outside any write transaction (Task 10 fills it; Task 11's migration fills it at
/// its step 0), so [`crate::scope::Caller::from_identity`] runs no git.
#[derive(Debug, Default)]
pub struct ProjectCache {
    dirs: HashMap<PathBuf, Option<(ProjectRef, Option<i64>)>>,
}

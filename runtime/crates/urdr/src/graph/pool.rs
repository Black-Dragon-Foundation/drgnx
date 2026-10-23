//! The read pool: 2–4 `mode=ro` connections from [`crate::open_readonly`] (never checkpoint), handed out one at a
//! time on a blocking thread, never held across an await by callers (Task 6).
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 6 removes this line.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use rusqlite::Connection;

/// Read-only connections to one database file; cheap to clone.
#[derive(Clone)]
pub struct ReadPool {
    path: Arc<PathBuf>,
    size: usize,
}

impl ReadPool {
    /// A pool of SIZE connections to PATH, opened when first used.
    pub fn open(path: impl Into<PathBuf>, size: usize) -> ReadPool {
        todo!("Task 6")
    }

    /// Run F with one connection, off the async workers, and give the connection back. `Err` when no connection
    /// could be opened.
    pub async fn with<R, F>(&self, f: F) -> crate::Result<R>
    where
        R: Send + 'static,
        F: FnOnce(&Connection) -> R + Send + 'static,
    {
        todo!("Task 6")
    }

    /// The database file.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

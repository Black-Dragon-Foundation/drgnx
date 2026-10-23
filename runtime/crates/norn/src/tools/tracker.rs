//! The tracker tools — `task_read`, `task_write`, `note_add` (Task 14; storage §6.1) — and the per-session tool list
//! (call 16).
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 14 removes this line.

use super::Ctx;

/// Which tool sets a session gets (call 16: on by default; a profile or a task turns them off).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ToolSets {
    /// The five tracker and graph tools.
    pub tracker: bool,
}

impl Default for ToolSets {
    fn default() -> Self {
        ToolSets { tracker: true }
    }
}

/// This file's tools (empty until Task 14).
pub fn tools() -> Vec<Box<dyn mimir::Tool<Ctx>>> {
    Vec::new()
}

/// The tools a session with SETS is served: 21 with the tracker tools, p2–p3's 16 without.
pub fn tools_for(sets: ToolSets) -> Vec<Box<dyn mimir::Tool<Ctx>>> {
    todo!("Task 14")
}

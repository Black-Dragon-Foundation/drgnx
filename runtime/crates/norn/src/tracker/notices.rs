//! Notices to the agents a change affects (Task 13; call 11): `message` rows of kind `task-changed`, coalesced per
//! task per recipient while unread, written in the change's tx.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 13 removes this line.

use urdr::Connection;

/// AGENT's unread notices (for `notices: n` on every tool answer).
pub fn notices_unread(conn: &Connection, agent: &str) -> Result<u32, urdr::SqliteError> {
    todo!("Task 13")
}

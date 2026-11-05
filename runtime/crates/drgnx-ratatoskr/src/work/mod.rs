//! The hub's Work-space facts: what each step read, searched or fetched, and the cores built on it (agent system
//! part 2; docs/develop/work-space.md).  The pure parts take no clock and do no I/O.
//!
//! - [`asks`]: the work a session does links to the user's message behind it (its current ask), in any turn.
//! - [`conclusions`]: the step each conclusion was recorded in, stamped by the hub, and the steps it rests on.
//! - [`bases`]: where each worktree branched from (the interim diff base), and which branch is based on which.
//! - [`detail`]: a step's detail by tool name.
//! - [`machines`]: the machines the hub lists (`local`, and those jobq reports with `machines/report`).
//! - [`map`]: the Work map: `vegvisir` fed from the sources above, and each map view's deltas, coalesced.
//! - [`presence`]: who is in which file, at which line, now (the presence model part 3 builds on).
//! - [`shell_read`]: the files a shell command names, parsed from its text and kept inside the workspace (layer 1 of
//!   "reads through shell commands").
//! - [`subagents`]: Claude Code's subagents, grouped under their parent by the `Task` call that started them.
//! - [`specs`]: a spec an agent writes becomes a `spec` entity at once.

pub mod asks;
pub mod bases;
pub mod conclusions;
pub mod detail;
pub mod edits;
pub mod machines;
pub mod map;
pub mod presence;
pub mod shell_read;
pub mod specs;
pub mod subagents;

//! The hub's Work-space facts: what each step read, searched or fetched, and the cores built on it (agent system
//! part 2; docs/develop/work-space.md).  The pure parts take no clock and do no I/O.
//!
//! - [`asks`]: the work a session does links to the user's message behind it (its current ask), in any turn.
//! - [`changes`]: what the agents changed, grouped by task, then file, then hunk (the Changes place's model).
//! - [`comments`]: paragraph comments: a thread on a paragraph of a record, steered to its writer, anchored by content.
//! - [`conclusions`]: the step each conclusion was recorded in, stamped by the hub, and the steps it rests on.
//! - [`bases`]: where each worktree branched from (the interim diff base), and which branch is based on which.
//! - [`budget_detail`]: the budget lines and the start step of a plan, pure (`forecast/start` reads it).
//! - [`target`]: `work/target/set`, the target date of a spec or a plan.
//!
//! The Work map, the trail, Timeline, Board, Flow and Schedule row builders (`map.rs`, `trail.rs`, `schedule.rs` and the
//! folders beside them) are switched off: see `REPLACED.md` in this folder.
//! - [`detail`]: a step's detail by tool name.
//! - [`machines`]: the machines the hub lists (`local`, and those jobq reports with `machines/report`).
//! - [`presence`]: who is in which file, at which line, now (the presence model part 3 builds on).
//! - [`shell_read`]: the files a shell command names, parsed from its text and kept inside the workspace (layer 1 of
//!   "reads through shell commands").
//! - [`subagents`]: Claude Code's subagents, grouped under their parent by the `Task` call that started them.
//! - [`specs`]: a spec an agent writes becomes a `spec` entity at once.
//! - [`task_effects`]: what a spec, plan or code change would do to the tasks under way (`review/effects`).
//! - [`trace`]: the files a shell step's processes opened, from Gleipnir's tracer (layer 2), labelled and kept within
//!   the trace budget.

pub mod asks;
pub mod bases;
pub mod budget_detail;
pub mod changes;
pub mod comments;
pub mod conclusions;
pub mod detail;
pub mod edit_lines;
pub mod edits;
pub mod machines;
pub mod presence;
pub mod shell_read;
pub mod specs;
pub mod subagents;
pub mod target;
pub mod task_effects;
pub mod trace;

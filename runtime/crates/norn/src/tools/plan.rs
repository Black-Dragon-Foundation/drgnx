//! The plan tools (agent system part 1, Task 21): `plan_read` (tasks with status, deps, interfaces and their reports'
//! interfaces) and `plan_write` (plans, tasks, steps and `blocks` links, under the matrix's `graph.change`), in
//! `runstav::methods::plans`'s shapes.

use mimir::Tool;
use runstav::methods::plans::{ByPlan, WriteParams};

use super::guard::guarded;
use super::{Ctx, stub_tool};

stub_tool!(
    PlanRead,
    "plan_read",
    ByPlan,
    "21",
    "A plan from the graph: its tasks with status, deps, interfaces, steps and what their reports produced."
);
stub_tool!(
    PlanWrite,
    "plan_write",
    WriteParams,
    "21",
    "Create or change a plan's tasks, steps and dependencies (needs the matrix's graph.change)."
);

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(PlanRead), guarded(PlanWrite)]
}

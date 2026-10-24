//! The structured report (agent system part 1, Task 21): `report_submit` makes a `report` entity linked to the task
//! (`report_of`), ledger notes, follow-up tasks (`discovered_from`), and moves the task to `in-review`.  Its arguments
//! are `runstav::methods::plans::ReportSubmit`, the same schema as the fallback `drgnx-report` block.

use mimir::Tool;
use runstav::methods::plans::ReportSubmit;

use super::guard::guarded;
use super::{Ctx, stub_tool};

stub_tool!(
    ReportSubmitTool,
    "report_submit",
    ReportSubmit,
    "21",
    "End your task with a structured report: tip, commits, checks run, decisions (with origin), differences from the brief, interfaces produced, follow-ups."
);

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(ReportSubmitTool)]
}

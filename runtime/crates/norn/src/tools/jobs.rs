//! The job tools (agent system part 1, Task 15; `docs/guide/jobs.md`): an agent starts a job and ends its turn; the
//! hub wakes it with the result.  No blocking wait: `job_result` and `job_log` are refused for a job's own starter
//! while it runs (Calls made 9).  Their answers are `runstav::methods::exec`'s shapes.

use mimir::Tool;
use runstav::methods::exec::{ById, LogParams, StartParams};

use super::guard::guarded;
use super::{Ctx, stub_tool};

stub_tool!(
    JobStart,
    "job_start",
    StartParams,
    "15",
    "Start a job (build, tests, a loop; kind container for an allowed image) in your worktree; answers its id. End your turn then: you are woken with the result."
);
stub_tool!(
    JobResult,
    "job_result",
    ById,
    "15",
    "A finished job's status, exit and summary (refused while your own job runs: you are woken instead)."
);
stub_tool!(
    JobLog,
    "job_log",
    LogParams,
    "15",
    "Lines of a finished job's log (refused while your own job runs)."
);
stub_tool!(JobStop, "job_stop", ById, "15", "Stop a job you started.");

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![
        guarded(JobStart),
        guarded(JobResult),
        guarded(JobLog),
        guarded(JobStop),
    ]
}

//! The plan tools (agent system part 1, Task 21): `plan_read` (tasks with status, deps, interfaces and their reports'
//! interfaces) and `plan_write` (plans, tasks, steps and `blocks` links, under the matrix's `graph.change`), in
//! `runstav::methods::plans`'s shapes.  The hub does the work (`plans/get`, `plans/write`) as the calling session.

use mimir::{BoxFuture, Tool};
use runstav::methods::plans::{ByPlan, WriteParams};

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};

fn session(who: &Identity) -> Result<&str, String> {
    match who {
        Identity::Session { sid, .. } => Ok(sid),
        _ => Err("only an agent session the hub runs reads or writes plans".into()),
    }
}

pub struct PlanRead;

impl CoordTool for PlanRead {
    type Args = ByPlan;
    const NAME: &'static str = "plan_read";
    const DESCRIPTION: &'static str = "A plan from the graph: its tasks with status, deps, interfaces, steps and what their reports produced.";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ByPlan,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let sid = session(who)?;
            let p = serde_json::to_value(&args).map_err(|e| e.to_string())?;
            Ok(coord.hub().exec(sid, "plans/get", p).await?.to_string())
        })
    }
}

pub struct PlanWrite;

impl CoordTool for PlanWrite {
    type Args = WriteParams;
    const NAME: &'static str = "plan_write";
    const DESCRIPTION: &'static str = "Create or change a plan's tasks, steps and dependencies (needs the matrix's graph.change).";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: WriteParams,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let sid = session(who)?;
            let p = serde_json::to_value(&args).map_err(|e| e.to_string())?;
            Ok(coord.hub().exec(sid, "plans/write", p).await?.to_string())
        })
    }
}

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(PlanRead), guarded(PlanWrite)]
}

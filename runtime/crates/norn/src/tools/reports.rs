//! The structured report (agent system part 1, Task 21): `report_submit` makes a `report` entity linked to the task
//! (`report_of`), ledger notes, follow-up tasks (`discovered_from`), and moves the task to `in-review`.  Its arguments
//! are `runstav::methods::plans::ReportSubmit`, the same schema as the fallback `drgnx-report` block.

use mimir::{BoxFuture, Tool};
use runstav::methods::plans::ReportSubmit;
use serde_json::json;

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};
use crate::store::CoordError;
use crate::write::reports::{file, task_of};

pub struct ReportSubmitTool;

impl CoordTool for ReportSubmitTool {
    type Args = ReportSubmit;
    const NAME: &'static str = "report_submit";
    const DESCRIPTION: &'static str = "End your task with a structured report: tip, commits, checks run, decisions (with origin), differences from the brief, interfaces produced, follow-ups.";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ReportSubmit,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            who.not_outside("report_submit")?;
            let me = who.me()?.to_owned();
            let sid = match who {
                Identity::Session { sid, .. } => Some(sid.clone()),
                _ => None,
            };
            let job = who.job().map(str::to_owned);
            let task = who.task().and_then(|t| {
                if t.starts_with("task:") {
                    Some(t.to_owned())
                } else if t.contains('#') {
                    Some(format!("task:{t}"))
                } else {
                    job.as_ref().map(|j| format!("task:{j}#{t}"))
                }
            });
            let now = coord.now();
            let filed = coord
                .db()
                .write(who.tx_meta("mcp:report_submit"), move |tx| {
                    let task = match &task {
                        Some(t) => t.clone(),
                        None => task_of(tx, &me, sid.as_deref())?.ok_or_else(|| {
                            CoordError::Refused("you hold no task to report on".into())
                        })?,
                    };
                    file(tx, &task, &me, sid.as_deref(), &args, now)
                })
                .await
                .map_err(|e| e.to_string())?;
            coord.hub().notify();
            Ok(json!({
                "ok": true, "report": filed.report, "followups": filed.followups,
                "unrecorded": filed.unrecorded,
            })
            .to_string())
        })
    }
}

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(ReportSubmitTool)]
}

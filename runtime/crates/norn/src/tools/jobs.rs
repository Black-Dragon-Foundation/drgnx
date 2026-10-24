//! The job tools (agent system part 1, Task 15; `docs/guide/jobs.md`): an agent starts a job and ends its turn; the
//! hub wakes it with the result.  No blocking wait: `job_result` and `job_log` are refused for a job's own starter
//! while it runs (Calls made 9), and after `agents-wait-refusals` refusals in one turn the hub cancels the turn.  Their
//! answers are `runstav::methods::exec`'s shapes; the jobs themselves are the hub's (`exec/*`, reached through
//! [`super::Hub::exec`] as the calling session).

use mimir::BoxFuture;
use runstav::methods::exec::{ById, LogParams, StartParams};
use serde_json::{Value, json};

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};
use mimir::Tool;

/// What `job_start` tells the agent.
pub const WOKEN: &str = "end your turn; you will be woken";

/// The session calling, and the folder it works in.
fn session(who: &Identity) -> Result<(&str, &std::path::Path), String> {
    match who {
        Identity::Session { sid, home, .. } => Ok((sid, home)),
        _ => Err("only an agent session the hub runs starts jobs".into()),
    }
}

/// The row of job ID and whether it runs for SID (its starter): the wait refusal's case.
async fn row(coord: &Coord, sid: &str, id: &str) -> Result<(Value, bool), String> {
    let row = coord.hub().exec(sid, "exec/get", json!({"id": id})).await?;
    let own = row.get("session").and_then(Value::as_str) == Some(sid);
    let running = matches!(
        row.get("status").and_then(Value::as_str),
        Some("running" | "queued")
    );
    Ok((row, own && running))
}

/// The refusal of a wait on a job that runs: counted by the hub.
fn refuse_wait(coord: &Coord, sid: &str, id: &str) -> String {
    coord.hub().wait_refused(sid);
    format!(
        "job {id} runs: end your turn, you are woken with its result (waiting or polling spends tokens for nothing)"
    )
}

pub struct JobStart;

impl CoordTool for JobStart {
    type Args = StartParams;
    const NAME: &'static str = "job_start";
    const DESCRIPTION: &'static str = "Start a job (build, tests, a loop; kind container for an allowed image) in your worktree; answers its id. End your turn then: you are woken with the result.";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: StartParams,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let (sid, home) = session(who)?;
            let mut params = serde_json::to_value(&args).map_err(|e| e.to_string())?;
            if params.get("cwd").is_none_or(Value::is_null) {
                params["cwd"] = json!(home.to_string_lossy());
            }
            let started = coord.hub().exec(sid, "exec/start", params).await?;
            let id = started.get("id").cloned().unwrap_or(Value::Null);
            // the hub says when the job waits for a slot ("queued"); either way the agent ends its turn
            let text = started.get("text").and_then(Value::as_str).unwrap_or(WOKEN);
            Ok(json!({"id": id, "text": text}).to_string())
        })
    }
}

pub struct JobResult;

impl CoordTool for JobResult {
    type Args = ById;
    const NAME: &'static str = "job_result";
    const DESCRIPTION: &'static str = "A finished job's status, exit and summary (refused while your own job runs: you are woken instead).";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ById,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let (sid, _) = session(who)?;
            let id = args.id.as_str();
            let (row, waiting) = row(coord, sid, id).await?;
            if waiting {
                return Err(refuse_wait(coord, sid, id));
            }
            Ok(row.to_string())
        })
    }
}

pub struct JobLog;

impl CoordTool for JobLog {
    type Args = LogParams;
    const NAME: &'static str = "job_log";
    const DESCRIPTION: &'static str =
        "Lines of a finished job's log (refused while your own job runs).";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: LogParams,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let (sid, _) = session(who)?;
            let id = args.id.as_str().to_string();
            let (_, waiting) = row(coord, sid, &id).await?;
            if waiting {
                return Err(refuse_wait(coord, sid, &id));
            }
            let params = serde_json::to_value(&args).map_err(|e| e.to_string())?;
            Ok(coord.hub().exec(sid, "exec/log", params).await?.to_string())
        })
    }
}

pub struct JobStop;

impl CoordTool for JobStop {
    type Args = ById;
    const NAME: &'static str = "job_stop";
    const DESCRIPTION: &'static str = "Stop a job you started.";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ById,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let (sid, _) = session(who)?;
            let id = args.id.as_str();
            let (row, _) = row(coord, sid, id).await?;
            if row.get("session").and_then(Value::as_str) != Some(sid) {
                return Err(format!("job {id} is not yours"));
            }
            Ok(coord
                .hub()
                .exec(sid, "exec/stop", json!({"id": id}))
                .await?
                .to_string())
        })
    }
}

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![
        guarded(JobStart),
        guarded(JobResult),
        guarded(JobLog),
        guarded(JobStop),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::CoordDb;
    use crate::tools::{Hub, SessionRow};
    use mimir::ToolResult;
    use std::sync::{Arc, Mutex};

    /// A hub whose jobs are a fixed table; it records the calls and the refused waits.
    #[derive(Default)]
    struct Jobs {
        calls: Mutex<Vec<(String, Value)>>,
        refused: Mutex<u32>,
        status: &'static str,
        owner: &'static str,
    }

    impl Hub for Jobs {
        fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>> {
            Box::pin(async { None })
        }
        fn notify(&self) {}
        fn exec(
            &self,
            sid: &str,
            method: &'static str,
            params: Value,
        ) -> BoxFuture<'_, Result<Value, String>> {
            self.calls
                .lock()
                .unwrap()
                .push((format!("{sid} {method}"), params.clone()));
            let row = json!({"id": "x1", "session": self.owner, "status": self.status});
            Box::pin(async move {
                Ok(match method {
                    "exec/start" => json!({"id": "x1", "text": "runs"}),
                    "exec/log" => json!({"id": "x1", "from": 0, "lines": ["a"], "running": false}),
                    _ => row,
                })
            })
        }
        fn wait_refused(&self, _sid: &str) {
            *self.refused.lock().unwrap() += 1;
        }
    }

    async fn call(hub: Arc<Jobs>, tool: &str, args: Value) -> (bool, String) {
        let dir = tempfile::tempdir().unwrap();
        let coord = Arc::new(Coord::new(CoordDb::spawn(dir.path().join("work.db")), hub));
        let who = Identity::Session {
            agent: "a".into(),
            sid: "s1".into(),
            profile: None,
            job: None,
            task: None,
            home: "/work/tree".into(),
        };
        let all = tools();
        let t = all.iter().find(|t| t.name() == tool).unwrap();
        t.check(&args).unwrap();
        match t.call(&(coord, who), args).await {
            ToolResult::Err(text) => (true, text),
            ToolResult::Ok { text, .. } | ToolResult::Rich { text, .. } => (false, text),
        }
    }

    fn hub(status: &'static str, owner: &'static str) -> Arc<Jobs> {
        Arc::new(Jobs {
            status,
            owner,
            ..Jobs::default()
        })
    }

    #[tokio::test]
    async fn job_start_runs_in_the_sessions_folder_and_says_end_your_turn() {
        let h = hub("running", "s1");
        let (err, text) = call(h.clone(), "job_start", json!({"argv": ["make"]})).await;
        assert!(!err, "{text}");
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["id"], "x1");
        // the hub's own text (it says "queued" for a job that waits for a slot) is passed on
        assert_eq!(v["text"], "runs");
        let calls = h.calls.lock().unwrap();
        assert_eq!(calls[0].0, "s1 exec/start");
        assert_eq!(calls[0].1["cwd"], "/work/tree");
    }

    #[tokio::test]
    async fn a_running_job_of_its_own_starter_is_not_waited_on() {
        for (tool, args) in [
            ("job_result", json!({"id": "x1"})),
            ("job_log", json!({"id": "x1"})),
        ] {
            let h = hub("running", "s1");
            let (err, text) = call(h.clone(), tool, args).await;
            assert!(err && text.contains("you are woken"), "{tool}: {text}");
            assert_eq!(*h.refused.lock().unwrap(), 1, "{tool} is counted");
        }
    }

    #[tokio::test]
    async fn a_finished_job_or_anothers_is_read() {
        for (status, owner) in [("done", "s1"), ("running", "s2")] {
            let h = hub(status, owner);
            let (err, text) = call(h.clone(), "job_result", json!({"id": "x1"})).await;
            assert!(!err, "{text}");
            assert_eq!(*h.refused.lock().unwrap(), 0);
        }
    }

    #[tokio::test]
    async fn job_stop_is_for_the_starter_only() {
        let (err, text) = call(hub("running", "s2"), "job_stop", json!({"id": "x1"})).await;
        assert!(err && text.contains("not yours"), "{text}");
        let (err, text) = call(hub("running", "s1"), "job_stop", json!({"id": "x1"})).await;
        assert!(!err, "{text}");
    }
}

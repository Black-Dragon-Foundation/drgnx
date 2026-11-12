//! Evidence (`docs/develop/orchestration.md`, "Evidence"): every job a task's session ran is recorded as that task's
//! `red` or `green` evidence once it ends, on the job's facts; `orch/evidence` reads a task's records.

use crate::dispatch::Caller;
use crate::exec::{JobEvent, Runner};
use crate::front::Front;
use runstav::methods::exec::ExecStatus;
use runstav::methods::orch::{ByTask, EvidenceList};
use runstav::wire::{Error, ErrorCode};
use std::sync::Arc;
use vordr::evidence::Evidence;
use vordr::rows::Verdict;

/// Job ID of RUNNER as evidence for TASK: `green` when it ended `done` with exit 0 and no failed row, else `red`; none
/// while it runs, for a job without facts (outside a git tree) or one whose result never counts (a `shared` runner's).
pub fn of_job(runner: &Runner, id: &str, task: &str) -> Option<Evidence> {
    if !runner.counts_for_gates(id) {
        return None;
    }
    let facts = runner.facts(id)?;
    let done = runner.done(id)?;
    let rows = runner.rows(id)?;
    let green = done.status == ExecStatus::Done
        && done.exit == Some(0)
        && !rows.iter().any(|r| r.verdict == Verdict::Fail);
    let (rows, truncated) = vordr::evidence::bounded(rows);
    Some(Evidence {
        kind: if green { "green" } else { "red" }.into(),
        task: task.to_string(),
        job: id.to_string(),
        facts,
        rows,
        truncated,
        at: crate::clock::wall_secs(),
        note: None,
    })
}

/// Why job ID of RUNNER is no evidence (`of_job` gave none): the words for the log.
fn no_evidence(runner: &Runner, id: &str) -> &'static str {
    if !runner.counts_for_gates(id) {
        "a shared runner's result, or no job"
    } else if runner.facts(id).is_none() {
        "no facts (its folder was outside a git tree)"
    } else if runner.done(id).is_none() {
        "it has not ended"
    } else {
        "no rows"
    }
}

/// Record E in the graph.
pub async fn record(front: &Front, e: Evidence) -> Result<(), Error> {
    let tx = urdr::graph::TxMeta::new("hub", urdr::graph::Class::System, "orch/evidence");
    front
        .writer
        .db
        .write(tx, move |tx| norn::write::evidence::record(tx, &e, None))
        .await
        .map(|_| ())
        .map_err(crate::coord::fail)
}

/// The task a session works on, as the agents' snapshots say.
fn task_of(front: &Front, session: &str) -> Option<String> {
    front
        .core
        .agents
        .snapshots()
        .into_iter()
        .find(|s| s.id == session)
        .and_then(|s| s.task)
}

/// Every job that ends whose session works on a task, or that a gate started for one, is that task's evidence (a hub
/// task of its own; it ends with the runner's events).
pub async fn run(front: Arc<Front>, mut rx: tokio::sync::broadcast::Receiver<JobEvent>) {
    loop {
        let done = match rx.recv().await {
            Ok(JobEvent::Done(d)) => d,
            Ok(_) => continue,
            // events were dropped: the gates' runs whose jobs ended meanwhile are settled now (a session's own job
            // missed here is no one's evidence; its next run is)
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!("the evidence watcher missed {n} job events");
                let ended = |id: &str| front.core.exec.done(id).is_some();
                for (id, run) in front.orch.take_ended(ended) {
                    settle(&front, &id, run).await;
                }
                continue;
            }
            Err(_) => return,
        };
        // a run a gate started is its task's
        if let Some(run) = front.orch.take(&done.id) {
            settle(&front, &done.id, run).await;
            continue;
        }
        let Some(task) = done.session.as_deref().and_then(|s| task_of(&front, s)) else {
            continue;
        };
        if let Some(e) = of_job(&front.core.exec, &done.id, &task)
            && let Err(err) = record(&front, e).await
        {
            tracing::warn!("job {}: evidence not recorded: {}", done.id, err.message);
        }
    }
}

/// Gate run ID whose tree moved while it ran, as TASK's run without a test result (`error`, so the gate holds at once
/// rather than starting it again: the same command moves the same tree), on the facts it had at submit, its note
/// naming the files that changed.  None for a run whose tree stayed.
pub fn moved_run(runner: &Runner, id: &str, task: &str) -> Option<Evidence> {
    let (files, facts) = runner.moved(id)?;
    Some(Evidence {
        kind: "red".into(),
        task: task.to_string(),
        job: id.to_string(),
        facts,
        rows: vec![vordr::rows::Row {
            name: vordr::rows::JOB_ROW.into(),
            verdict: Verdict::Fail,
            class: Some(vordr::rows::Class::Error),
            symbols: Vec::new(),
        }],
        truncated: false,
        at: crate::clock::wall_secs(),
        note: Some(crate::exec::moved_line(&files)),
    })
}

/// Gate run RUN (job ID) ended: its evidence for its task (or, when its tree moved, the run that holds the gate), then
/// its detached worktree goes.
pub async fn settle(front: &Front, id: &str, run: crate::orch::gates::Run) {
    match of_job(&front.core.exec, id, &run.task)
        .or_else(|| moved_run(&front.core.exec, id, &run.task))
    {
        Some(e) => {
            let kind = e.kind.clone();
            match record(front, e).await {
                Ok(()) => tracing::info!(task = run.task, job = id, "the gate's run ended: {kind}"),
                Err(err) => tracing::warn!("job {id}: evidence not recorded: {}", err.message),
            }
        }
        None => tracing::warn!(
            task = run.task,
            job = id,
            "the gate's run ended with no evidence: {}",
            no_evidence(&front.core.exec, id)
        ),
    }
    let _ = crate::clock::blocking(move || crate::orch::gates::cleanup(&run)).await;
}

/// `orch/evidence`: a task's evidence, oldest first.
pub async fn list(front: &Front, _: &Caller, p: ByTask) -> Result<EvidenceList, Error> {
    let task = p.task.as_str().to_owned();
    let found = front
        .writer
        .db
        .read(move |c| norn::read::evidence::of_task(c, &task))
        .await
        .map_err(crate::coord::fail)?;
    let evidence = found
        .into_iter()
        .map(|e| {
            serde_json::to_value(e).map_err(|err| Error {
                code: ErrorCode::Internal,
                message: err.to_string(),
                path: None,
            })
        })
        .collect::<Result<_, _>>()?;
    Ok(EvidenceList { evidence })
}

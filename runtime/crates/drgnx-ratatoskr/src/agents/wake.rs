//! Waking instead of polling (agent system part 1, Task 15; `docs/guide/jobs.md`): the hub listens to the runner and
//! prompts the session that started a job when the job ends, with its summary.  The session between the job's start
//! and its end spends no model request; one idle past `agents-close-idle-after` is closed and resumed here.

use crate::exec::JobEvent;
use crate::front::Front;
use runstav::methods::exec::{ExecDone, ExecStatus};
use std::sync::Arc;

/// What the woken agent reads: the job, how it ended, the parsed summary and where the whole log is.
pub fn wake_text(d: &ExecDone) -> String {
    let how = match (d.status, d.exit) {
        (ExecStatus::Done, Some(n)) => format!("exit {n}"),
        (ExecStatus::Done, None) => "exit unknown".to_string(),
        (ExecStatus::Stopped, _) => "stopped".to_string(),
        (ExecStatus::TimedOut, _) => "timed out".to_string(),
        _ => "lost".to_string(),
    };
    let mut text = format!("[job {} finished — {how}]", d.id);
    if !d.summary.failing.is_empty() {
        text.push_str(&format!(" failing: {}.", d.summary.failing.join(", ")));
    }
    for line in &d.summary.lines {
        text.push('\n');
        text.push_str(line);
    }
    text.push_str(&format!(
        "\nthe whole log: {} (job_log {} reads a slice)",
        d.summary.log, d.id
    ));
    text
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

/// A wake that has to be delivered is a `wake` row of `runtime.db` (migration 7): `pending`, `sending` while a
/// delivery claims it.  It is deleted once the session has the prompt, so a restart wakes once: a row left `pending`
/// is delivered again at the next start, one left `sending` only when the session does not hold the prompt.
async fn write<R: Send + 'static>(
    front: &Front,
    f: impl FnOnce(&urdr::Connection) -> Result<R, urdr::Error> + Send + 'static,
) -> Option<R> {
    match front.core.agents.db()?.write(f).await {
        Ok(r) => Some(r),
        Err(e) => {
            tracing::warn!("wake not kept: {e}");
            None
        }
    }
}

/// File the end of a job as a wake to deliver (once).
async fn record(front: &Front, done: &ExecDone) {
    let Some(sid) = done.session.clone() else {
        return;
    };
    let (job, at) = (done.id.clone(), now());
    write(front, move |c| {
        Ok(c.execute(
            "insert or ignore into wake(job, session, state, at) values (?1, ?2, 'pending', ?3)",
            (job, sid, at),
        )?)
    })
    .await;
}

/// Take the wake of JOB for delivery; false when another delivery has it, or it is gone.
async fn claim(front: &Front, job: &str) -> bool {
    let job = job.to_string();
    write(front, move |c| {
        Ok(c.execute(
            "update wake set state = 'sending' where job = ?1 and state = 'pending'",
            [job],
        )? == 1)
    })
    .await
    .unwrap_or(false)
}

/// Deliver JOB's end to its session: claimed, prompted (resuming it if it was closed), then deleted.  A session that
/// is not there yet leaves it `pending` for [`recover`].
async fn deliver(front: &Front, done: &ExecDone) {
    let Some(sid) = done.session.clone() else {
        return;
    };
    if !claim(front, &done.id).await {
        return;
    }
    let job = done.id.clone();
    match front.core.agents.wake(front, &sid, wake_text(done)).await {
        Ok(()) => {
            write(front, move |c| {
                Ok(c.execute("update wake set state = 'done' where job = ?1", [job])?)
            })
            .await;
        }
        Err(e) => {
            tracing::warn!(sid, job = done.id, "no wake yet: {}", e.message);
            write(front, move |c| {
                Ok(c.execute("update wake set state = 'pending' where job = ?1", [job])?)
            })
            .await;
        }
    }
}

/// After the sessions are back: every wake still on file is delivered, unless the session already holds it (it was
/// prompted just before the hub went down).
pub async fn recover(front: &Front) {
    let Some(rows) = write(front, |c| {
        let mut q = c.prepare("select job, session, state from wake order by at")?;
        let rows = q
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<Result<Vec<(String, String, String)>, _>>()?;
        Ok(rows)
    })
    .await
    else {
        return;
    };
    let known: std::collections::HashSet<String> = rows.iter().map(|r| r.0.clone()).collect();
    for (job, sid, state) in rows {
        let Some(done) = front.core.exec.done(&job) else {
            let job = job.clone();
            write(front, move |c| {
                Ok(c.execute("delete from wake where job = ?1", [job])?)
            })
            .await;
            continue;
        };
        if state == "done" {
            continue;
        }
        if state == "sending" {
            let held = front
                .core
                .agents
                .find(&sid)
                .is_ok_and(|s| s.holds_text(&format!("[job {job} finished")));
            let job = job.clone();
            if held {
                write(front, move |c| {
                    Ok(c.execute("update wake set state = 'done' where job = ?1", [job])?)
                })
                .await;
                continue;
            }
            write(front, move |c| {
                Ok(c.execute("update wake set state = 'pending' where job = ?1", [job])?)
            })
            .await;
        }
        deliver(front, &done).await;
    }
    // a job that ended with no row on file: the hub died between its result and the row
    for r in front.core.exec.list(None, false) {
        let Some(sid) = r.session.clone() else {
            continue;
        };
        if r.status == ExecStatus::Running || known.contains(&r.id) {
            continue;
        }
        let held = front
            .core
            .agents
            .find(&sid)
            .map_or(true, |s| s.holds_text(&format!("[job {} finished", r.id)));
        let Some(done) = front.core.exec.done(&r.id) else {
            continue;
        };
        if held {
            continue;
        }
        record(front, &done).await;
        deliver(front, &done).await;
    }
}

/// Until the hub ends: queue waits are steps, a job's end is a prompt to its starter.  EVENTS was subscribed before
/// the jobs of a hub before this one were watched again, so none of their ends is missed.
pub async fn run(front: Arc<Front>, mut events: tokio::sync::broadcast::Receiver<JobEvent>) {
    loop {
        match events.recv().await {
            Ok(JobEvent::Queued {
                session: Some(sid), ..
            }) => {
                if let Ok(s) = front.core.agents.find(&sid) {
                    s.queue_wait(true);
                }
            }
            Ok(JobEvent::Admitted {
                session: Some(sid), ..
            }) => {
                if let Ok(s) = front.core.agents.find(&sid) {
                    s.queue_wait(false);
                }
            }
            Ok(JobEvent::Done(done)) => {
                if done.session.is_some() {
                    let front = front.clone();
                    tokio::spawn(async move {
                        super::die_at("before-wake-row");
                        record(&front, &done).await;
                        deliver(&front, &done).await;
                    });
                }
            }
            Ok(_) => {}
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!("{n} job events missed");
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use runstav::methods::exec::ExecSummary;

    fn done(status: ExecStatus, exit: Option<i32>, failing: &[&str]) -> ExecDone {
        ExecDone {
            id: "x1".into(),
            session: Some("s1".into()),
            status,
            exit,
            summary: ExecSummary {
                exit,
                failing: failing.iter().map(|s| s.to_string()).collect(),
                lines: vec!["1 test failed".into()],
                log: "/state/exec/x1/log".into(),
            },
        }
    }

    #[test]
    fn the_wake_names_the_job_its_end_and_where_the_log_is() {
        let t = wake_text(&done(ExecStatus::Done, Some(101), &["a::b"]));
        assert!(t.starts_with("[job x1 finished — exit 101]"), "{t}");
        assert!(t.contains("failing: a::b"), "{t}");
        assert!(
            t.contains("1 test failed") && t.contains("/state/exec/x1/log"),
            "{t}"
        );
        assert!(wake_text(&done(ExecStatus::TimedOut, None, &[])).contains("timed out"));
        assert!(wake_text(&done(ExecStatus::Stopped, None, &[])).contains("stopped"));
    }
}

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

/// Until the hub ends: queue waits are steps, a job's end is a prompt to its starter.
pub async fn run(front: Arc<Front>) {
    let mut events = front.core.exec.subscribe();
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
                if let Some(sid) = done.session.clone() {
                    let front = front.clone();
                    tokio::spawn(async move {
                        let text = wake_text(&done);
                        if let Err(e) = front.core.agents.wake(&front, &sid, text).await {
                            tracing::warn!(sid, job = done.id, "no wake: {}", e.message);
                        }
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

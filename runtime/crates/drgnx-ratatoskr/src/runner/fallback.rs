//! Plan runs: a provider at its limit and a budget reached (Task 16b; `drgnx-job--fall-back`,
//! `drgnx-job--gateway-event`, `drgnx-job-resume` are the oracle).
//!
//! - **Fallback.**  A worker whose turn ended in an error that says its provider is at its limit (a 429, a rate limit,
//!   overload, a quota) hands its task to the next profile of the task's role route, in the same tree, with a
//!   handover (its last commit and last words); with none left the task gets a `fallback` card.  A reviewer at its
//!   limit starts again on the next profile of the `review` route, else a `review` card.
//! - **Budget pause.**  A budget limit reached below a plan run pauses the job (its sessions were already paused after
//!   their tool call by [`crate::budget`]) and makes the job's `budget` card; `job/resume` (optionally with a new
//!   USD budget) sets it running and lets the paused sessions go on.

use super::{
    Caller, Error, Loaded, changed, data_of, invalid, load, now, raise_card, route, service,
    settle_cards, summary, tick,
};
use crate::front::Front;
use norn::read::jobs::Job;
use norn::read::tasks::Task;
use norn::write::jobs::job_set;
use norn::write::tasks::force_status;
use runstav::methods::agents::{AgentOp, DoParams, EntryType, SessionStatus, Snapshot, Transcript};
use runstav::methods::jobs::{JobSummary, WithBudget};
use runstav::methods::matrix::{Limit, Unit};
use runstav::methods::timeline::BudgetScope;
use runstav::types::{Bounded, Id};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;

/// Does TEXT say a provider is at its limit (`drgnx-job--provider-limit`, case ignored)?
pub(crate) fn provider_limit(text: &str) -> bool {
    let t = text.to_lowercase();
    if [
        "rate limit",
        "rate_limit",
        "rate-limit",
        "ratelimit",
        "overloaded",
        "quota",
        "too many requests",
    ]
    .iter()
    .any(|w| t.contains(w))
    {
        return true;
    }
    // a 429 as a number of its own
    t.match_indices("429").any(|(i, _)| {
        let before = t[..i].chars().next_back();
        let after = t[i + 3..].chars().next();
        !before.is_some_and(|c| c.is_ascii_digit()) && !after.is_some_and(|c| c.is_ascii_digit())
    })
}

/// How a session's last turn ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Ended {
    /// The turn failed and the provider is at its limit (the error's text).
    Limit(String),
    /// The turn ended (the agent's answer is in the transcript).
    Stopped,
}

/// The way the last turn of T ended: its last `stop` or `error` entry (none: still going, or never began).
pub(crate) fn ended(t: &Transcript) -> Option<Ended> {
    t.entries
        .iter()
        .rev()
        .find_map(|e| match e.kind {
            EntryType::Stop => Some(Ended::Stopped),
            EntryType::Error => {
                let text = text_of(e);
                provider_limit(&text).then_some(Ended::Limit(text))
            }
            _ => None,
        })
        .or_else(|| {
            let err = t.entries.last().filter(|e| e.kind == EntryType::Error)?;
            (!provider_limit(&text_of(err))).then_some(Ended::Stopped)
        })
}

fn text_of(e: &runstav::methods::agents::Entry) -> String {
    e.rest
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned()
}

/// The limit that ended worker session S, which has exited: its stderr or its last failed turn says its provider was at
/// its limit (the text), else none.
pub(crate) fn exit_limit(s: &Snapshot, t: Option<&Transcript>) -> Option<String> {
    if s.status != Some(SessionStatus::Exited) {
        return None;
    }
    let err = s.stderr.as_deref().unwrap_or("");
    if provider_limit(err) {
        let n = err.chars().count();
        return Some(err.chars().skip(n.saturating_sub(300)).collect());
    }
    match t.and_then(ended) {
        Some(Ended::Limit(why)) => Some(why),
        _ => None,
    }
}

/// What the agent said in its last turn (the `agent` entries after the last `user` one).
pub(crate) fn said(t: &Transcript) -> String {
    let from = t
        .entries
        .iter()
        .rposition(|e| e.kind == EntryType::User)
        .map_or(0, |i| i + 1);
    t.entries[from..]
        .iter()
        .filter(|e| e.kind == EntryType::Agent)
        .map(text_of)
        .collect()
}

/// The text of the agent's last message (a reviewer's verdict is in its last line).
pub(crate) fn last_said(t: &Transcript) -> String {
    t.entries
        .iter()
        .rev()
        .find(|e| e.kind == EntryType::Agent)
        .map(text_of)
        .unwrap_or_default()
}

/// TEXT as a Markdown quote.
pub(crate) fn quote(text: &str) -> String {
    text.split('\n')
        .map(|l| format!("> {l}"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// `job/...` status of TASK set to STATUS held by AGENT (the tick's writer).
pub(crate) async fn set_status(
    front: &Front,
    task: &str,
    status: &'static str,
    agent: Option<String>,
) -> Result<(), Error> {
    let t = task.to_owned();
    front
        .writer
        .write(&service(), "job/step", move |tx| {
            force_status(tx, &t, status, agent.as_deref(), now()).map(|_| ())
        })
        .await
        .map_err(crate::coord::fail)
}

/// What worker session TR leaves its successor on TASK: its last commit (read in the trusted repository) and its last
/// words.
async fn handover(front: &Front, job: &str, task: &Task, tr: &Transcript) -> String {
    let repo = match load(front, job, false).await {
        Ok(Some(l)) => PathBuf::from(l.job.repo.unwrap_or_default()),
        _ => PathBuf::new(),
    };
    let range = format!("job/{job}..job/{job}-{}", task.row.n);
    let commit = tick::git(&repo, &["log", "-1", "--format=%h %s", &range])
        .await
        .unwrap_or_default();
    let said = said(tr);
    let tail: String = {
        let n = said.chars().count();
        said.chars().skip(n.saturating_sub(2000)).collect()
    };
    format!(
        "You are continuing this task: an agent began it here and stopped (its provider failed).  Its last commit: {}.{}\n\n",
        if commit.is_empty() { "none" } else { &commit },
        if tail.trim().is_empty() {
            String::new()
        } else {
            format!("  Its last words:\n{}", quote(&tail))
        }
    )
}

/// The worker session of TASK (job JOB) is at its provider's limit (WHY): the task goes to the next profile of its
/// role's route, in the same tree (a `fallback` event), or to the user when there is none.
pub(crate) async fn worker(
    front: &Arc<Front>,
    job: &str,
    task: &Task,
    snap: &Snapshot,
    tr: &Transcript,
    why: &str,
) -> Result<(), Error> {
    let runs = &front.core.runs;
    let tid = task.row.id.as_str();
    let from = snap.profile.clone().unwrap_or_default();
    let routes = route(front, task.row.role.as_deref().unwrap_or("implement"));
    let to = routes
        .iter()
        .position(|p| *p == from)
        .and_then(|i| routes.get(i + 1))
        .cloned();
    let Some(to) = to else {
        raise_card(
            front,
            &service(),
            job,
            Some(tid),
            "fallback",
            &format!("{from} failed ({why}); no other profile on the route"),
            json!({}),
        )
        .await?;
        return Ok(());
    };
    let note = handover(front, job, task, tr).await;
    runs.set_busy(tid, Some("starting"));
    let _ = front.core.agents.kill(&snap.id).await;
    runs.session_finished(front, &snap.id);
    let started = match set_status(front, tid, "ready", None).await {
        Ok(()) => tick::start(front, job, task, Some(&note), Some(&to)).await,
        Err(e) => Err(e),
    };
    runs.set_busy(tid, None);
    front.broadcast(
        "fallback",
        json!({"job": job, "task": tid, "agent": snap.name, "from": from, "to": to, "why": why}),
    );
    changed(front, job).await;
    started
}

// ---- the budget pause -------------------------------------------------------------------------------------------

/// A budget limit was reached below job JOB: the running job pauses and its `budget` card is made (its id; none when
/// the job was not running).
pub async fn pause_job(front: &Front, job: &str, title: &str, data: Value) -> Option<i64> {
    let l = load(front, job, false).await.ok().flatten()?;
    if l.job.status.as_deref() != Some("running") {
        return None;
    }
    let jid = job.to_owned();
    let paused = front
        .writer
        .write(&service(), "coord/job-set", move |tx| {
            job_set(tx, &jid, Some("paused"), None, now())
        })
        .await;
    if let Err(e) = paused {
        tracing::warn!("plan run {job}: not paused: {e:?}");
        return None;
    }
    let card = raise_card(front, &service(), job, None, "budget", title, data).await;
    changed(front, job).await;
    card.map_err(|e| tracing::warn!("plan run {job}: no budget card: {}", e.message))
        .ok()
}

/// The USD budget of JOB's plan scope: USD in all.  BIND books the gateway's spend of the job under it (the approval
/// does; a resume keeps what the sessions bound).
pub(crate) fn set_budget(front: &Front, job: &Job, usd: f64, bind: bool) {
    let plan = job
        .plan
        .as_deref()
        .map(|p| format!("plan:{p}"))
        .unwrap_or_else(|| format!("plan:{}", job.id));
    let scope = BudgetScope::Plan(Bounded(plan));
    let b = &front.core.budgets;
    b.enroll(&scope);
    let hits = b.set(
        &scope,
        vec![Limit {
            amount: usd,
            unit: Unit::Usd,
        }],
    );
    if bind {
        b.bind_job(&job.id, &scope);
    }
    b.save();
    b.notify(hits);
}

/// `job/resume`: go on with paused or stopped job ID, with BUDGET USD for the whole job when given; the sessions the
/// pause held go on, the stopped ones' tasks are free for new agents.
pub async fn resume(front: &Front, caller: &Caller, p: WithBudget) -> Result<JobSummary, Error> {
    let id = p.id.as_str();
    let l: Loaded = load(front, id, false)
        .await?
        .ok_or_else(|| invalid(format!("No job {id}")))?;
    let status = l.job.status.clone().unwrap_or_default();
    if !matches!(status.as_str(), "paused" | "stopped") {
        return Err(invalid(format!("Job {id} is {status}, not paused")));
    }
    let mut data = data_of(&l.job);
    if let Some(b) = p.budget.map(|b| b.get()) {
        data.insert("budget".into(), json!(b));
        set_budget(front, &l.job, b, false);
    }
    let jid = id.to_owned();
    front
        .writer
        .write(caller, "coord/job-set", move |tx| {
            job_set(
                tx,
                &jid,
                Some("running"),
                Some(&Value::Object(data.clone())),
                now(),
            )
        })
        .await
        .map_err(crate::coord::fail)?;
    settle_cards(front, caller, id, |c| {
        (c.kind.as_deref() == Some("budget")).then_some("resume")
    })
    .await?;
    for s in front.core.agents.snapshots() {
        if s.job.as_deref() == Some(id)
            && s.paused == Some(true)
            && s.status != Some(SessionStatus::Exited)
            && let Ok(sid) = Id::new(s.id.clone())
        {
            let _ = front
                .core
                .agents
                .do_op(
                    caller,
                    DoParams {
                        id: sid,
                        op: AgentOp::DeliverQueue,
                        n: None,
                        text: None,
                        item: None,
                        reject: None,
                    },
                )
                .await;
        }
    }
    front.core.runs.wake();
    changed(front, id).await;
    summary(front, id, false).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use runstav::methods::agents::Entry;
    use serde_json::Map;

    fn entry(kind: EntryType, text: &str) -> Entry {
        let mut rest = Map::new();
        rest.insert("text".into(), json!(text));
        Entry { kind, rest }
    }

    fn transcript(entries: Vec<Entry>) -> Transcript {
        Transcript {
            session: serde_json::from_value(json!({"id": "s1"})).unwrap(),
            entries,
            seq: 0,
        }
    }

    #[test]
    fn a_provider_at_its_limit_is_known_by_what_it_says() {
        for yes in [
            "HTTP 429 Too Many Requests",
            "error 429: slow down",
            "Rate limit exceeded",
            "rate_limit_error",
            "the model is overloaded",
            "You exceeded your current quota",
        ] {
            assert!(provider_limit(yes), "{yes}");
        }
        for no in ["port 14290 refused", "compile error", "the 4290th line", ""] {
            assert!(!provider_limit(no), "{no}");
        }
    }

    #[test]
    fn a_turn_ends_in_a_stop_or_in_a_limit_error() {
        let t = transcript(vec![
            entry(EntryType::User, "go"),
            entry(EntryType::Agent, "done"),
            entry(EntryType::Stop, ""),
        ]);
        assert_eq!(ended(&t), Some(Ended::Stopped));
        let t = transcript(vec![
            entry(EntryType::User, "go"),
            entry(EntryType::Error, "429 rate limit"),
        ]);
        assert_eq!(ended(&t), Some(Ended::Limit("429 rate limit".into())));
        // an error that is not a limit ends the turn too: the nudge's business, not the fallback's
        let t = transcript(vec![entry(EntryType::Error, "boom")]);
        assert_eq!(ended(&t), Some(Ended::Stopped));
        assert_eq!(ended(&transcript(vec![entry(EntryType::User, "go")])), None);
    }

    #[test]
    fn what_the_agent_said_is_its_last_turns_text() {
        let t = transcript(vec![
            entry(EntryType::Agent, "old"),
            entry(EntryType::User, "go"),
            entry(EntryType::Agent, "VERDICT: "),
            entry(EntryType::Agent, "pass"),
        ]);
        assert_eq!(said(&t), "VERDICT: pass");
        assert_eq!(quote("a\nb"), "> a\n> b");
    }
}

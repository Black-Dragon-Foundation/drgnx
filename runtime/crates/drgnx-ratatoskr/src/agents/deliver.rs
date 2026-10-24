//! Delivery, ported from `drgnx-hub--deliver` (free agents only, quoted peer headers, the decision-log notice once
//! per version, the freshness gate on `edit|delete|move|execute`), and take-back: `messages/retract` succeeds only
//! while the message is queued (Task 24).
//!
//! A queued message stays in the store until its recipient session is free (idle, not held by a Stop, nothing
//! queued): then it is prompted as a new turn, never an interruption, and marked delivered and read.  The store is
//! the queue, so a message queued across a hub restart is delivered after the sessions resume.

use super::queue::Origin;
use super::session::Session;
use crate::dispatch::Caller;
use crate::front::Front;
use norn::read::{decisions, messages as read};
use norn::write::messages::{self, NoticeChange};
use runstav::methods::coord::{RetractParams, Retracted};
use runstav::registry::Class;
use runstav::wire::{Error, ErrorCode};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

/// A pass at least this often (a session turning free is not announced).
const EVERY: Duration = Duration::from_secs(1);

/// `messages/retract`: the user's message taken back while it is still `queued`; once anyone was given it, the answer
/// says `retracted: false` and the state it has.
pub async fn retract(f: &Front, c: &Caller, p: RetractParams) -> Result<Retracted, Error> {
    let id = p.id as i64;
    let r = f
        .writer
        .write(c, "messages/retract", move |tx| messages::retract(tx, id))
        .await
        .map_err(crate::coord::fail)?;
    match r {
        Some((retracted, status)) => Ok(Retracted { retracted, status }),
        None => Err(Error {
            code: ErrorCode::InvalidParams,
            message: format!("no message {id}"),
            path: Some("id".into()),
        }),
    }
}

fn notice_changes(ch: Vec<decisions::Decision>) -> Vec<NoticeChange> {
    ch.into_iter()
        .map(|d| NoticeChange {
            n: d.n,
            kind: d.kind.unwrap_or_default(),
            subject: d.subject.unwrap_or_default(),
            status: d.status.unwrap_or_default(),
        })
        .collect()
}

/// What session S of JOB is behind on: the log's version, what it last read and the notice's changes (none: it is
/// not behind).
async fn behind(s: &Session, job: &str) -> Option<(u64, u64, Vec<NoticeChange>)> {
    let (sid, job) = (s.id.clone(), job.to_string());
    let got = s
        .coord()
        .db
        .read(move |tx| {
            let (seen, v) = (decisions::seen(tx, &sid)?, decisions::version(tx)?);
            if seen >= v {
                return Ok(None);
            }
            let ch = decisions::decisions_since(tx, seen, Some(&job))?;
            Ok(Some((v, seen, ch)))
        })
        .await
        .ok()??;
    (!got.2.is_empty()).then(|| (got.0, got.1, notice_changes(got.2)))
}

/// The freshness gate: a job's agent asks to edit, delete, move or run something while it is behind the decision log.
/// True: the call is refused, and (once per version) the changes are put at the front of its queue.  Reading is
/// never held, and an agent of no job never is.
pub(crate) async fn gate(s: &Arc<Session>, tool: Option<&Value>) -> bool {
    let kind = tool
        .and_then(|t| t.get("kind"))
        .and_then(Value::as_str)
        .unwrap_or("");
    if !matches!(kind, "edit" | "delete" | "move" | "execute") {
        return false;
    }
    let Some(job) = s.job_id().map(str::to_string) else {
        return false;
    };
    let Some((v, seen, changes)) = behind(s, &job).await else {
        return false;
    };
    if s.gate_told(v) {
        let text = format!(
            "{}\nYour last tool call was refused because you had not read these.",
            messages::notice(v, &job, &changes, seen)
        );
        s.steer_in(text);
    }
    true
}

/// The hub's own writes to the store (actor `hub`, class system).
fn hub_caller() -> Caller {
    Caller {
        class: Class::User,
        sid: None,
        job: None,
        conn_id: 0,
        backend: false,
    }
}

/// One pass: each queued message to its recipient session when that is free, then the decision-log notice to each
/// free job agent that is behind it (once per version, in TOLD).
pub(crate) async fn pass(front: &Front, told: &mut HashMap<String, u64>) {
    let sessions = front.core.agents.live_sessions();
    if sessions.is_empty() {
        return;
    }
    let queued = front
        .writer
        .db
        .read(|tx| {
            let mut out = Vec::new();
            for m in read::queued(tx)? {
                let q = read::message_answers(tx, m.id)?;
                out.push((m, q));
            }
            Ok(out)
        })
        .await
        .unwrap_or_default();
    for (m, q) in queued {
        let Some(s) = m
            .recipient
            .as_deref()
            .and_then(|r| sessions.iter().find(|s| s.is_for(r)))
        else {
            continue;
        };
        if !s.is_free() {
            continue;
        }
        let origin = match m.sender.as_deref() {
            None | Some("user") => Origin::User,
            Some(from) => Origin::Peer(from.to_string()),
        };
        // the prompt is queued (and kept on disk) before the message is marked: a restart between the two delivers it
        // twice rather than never
        if s.prompt(messages::message_prompt(&m, q.as_ref()), origin)
            .is_err()
        {
            continue;
        }
        let id = m.id;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        let marked = front
            .writer
            .write(&hub_caller(), "coord/deliver", move |tx| {
                messages::mark(tx, id, "delivered", now)?;
                messages::mark(tx, id, "read", now)
            })
            .await;
        if let Err(e) = marked {
            tracing::warn!(message = id, "delivered but not marked: {e}");
        }
    }
    let version = front.writer.db.read(decisions::version).await.unwrap_or(0);
    if version == 0 {
        return;
    }
    for s in &sessions {
        let Some(job) = s.job_id() else { continue };
        if told.get(&s.id).copied().unwrap_or(0) >= version || !s.is_free() {
            continue;
        }
        if let Some((v, seen, changes)) = behind(s, job).await {
            told.insert(s.id.clone(), v);
            let _ = s.prompt(messages::notice(v, job, &changes, seen), Origin::Hub);
        }
    }
}

/// Until the hub ends: a pass whenever a write may have added a message, and every second.
pub async fn run(front: Arc<Front>) {
    let mut told = HashMap::new();
    loop {
        tokio::select! {
            () = front.writer.signals.deliver.notified() => {}
            () = tokio::time::sleep(EVERY) => {}
        }
        pass(&front, &mut told).await;
    }
}

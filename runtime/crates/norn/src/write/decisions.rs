//! The decision log's writers (Task 6): `drgnx-coord--held` and `drgnx-coord-decide` (`core/drgnx-coord.el`).

use super::event::{Event, EventKind, event};
use super::meta;
use super::tasks::ACTIVE;
use crate::read::decisions::{Decision, decisions_since};
use crate::read::tasks::{opt, task_row};
use crate::store::{CoordError, Tx};
use serde_json::json;

/// Decisions one agent may record per minute; more are refused (`drgnx-coord-decision-rate`).
pub const DECISION_RATE: i64 = 6;

/// The write was held: the log moved on since the writer read it (`(:held t :version V :changes DECISIONS)`).
#[derive(Debug, Clone, PartialEq)]
pub struct Held {
    pub version: u64,
    /// The decisions after the writer's version, newest first.
    pub changes: Vec<Decision>,
}

/// `None` when SEEN is the current version (or absent); else the held answer.  A SEEN the log has not reached is
/// refused (`drgnx-coord--held`).
pub fn held_check(tx: &Tx, seen: Option<u64>) -> Result<Option<Held>, CoordError> {
    let v = meta::version(tx)?;
    let Some(seen) = seen else { return Ok(None) };
    if seen > v {
        return Err(CoordError::Refused(format!(
            "seen_version {seen} is from the future: the decision log is at {v} (call read_decisions)"
        )));
    }
    if v > seen {
        return Ok(Some(Held {
            version: v,
            changes: decisions_since(tx, seen, None)?,
        }));
    }
    Ok(None)
}

/// What `drgnx-coord-decide` takes.
#[derive(Debug, Clone, Default)]
pub struct Decide {
    pub kind: String,
    pub subject: String,
    pub task: Option<String>,
    pub paths: Option<String>,
    pub reason: Option<String>,
    pub author: String,
    pub seen: Option<u64>,
    /// A decision's number: marked replaced when this one is current.
    pub replaces: Option<i64>,
    pub job: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DecideResult {
    Ok {
        n: i64,
        status: String,
        version: u64,
    },
    Held(Held),
    Error(String),
}

/// Record a decision of JOB by AUTHOR, who read the log at SEEN, at time NOW (`drgnx-coord-decide`).  The user's is
/// current; an agent's is current inside its own claimed TASK (and, when replacing, only its own decision of that
/// task), else proposed.  More than [`DECISION_RATE`] a minute from one agent are refused.
pub fn decide(tx: &Tx, d: Decide, now: f64) -> Result<DecideResult, CoordError> {
    if let Some(h) = held_check(tx, d.seen)? {
        return Ok(DecideResult::Held(h));
    }
    let user = d.author == "user";
    if !user {
        let recent: i64 = tx.query_row(
            "select count(*) from decision where author = ?1 and at > ?2",
            (&d.author, now - 60.0),
            |r| r.get(0),
        )?;
        if recent >= DECISION_RATE {
            return Ok(DecideResult::Error(format!(
                "too many decisions in a minute ({DECISION_RATE}): wait, or ask the user"
            )));
        }
    }
    let own = match (&d.task, user) {
        (Some(task), false) => task_row(tx, task)?.is_some_and(|row| {
            row.agent.as_deref() == Some(d.author.as_str())
                && row.status.as_deref().is_some_and(|s| ACTIVE.contains(&s))
        }),
        _ => false,
    };
    let replaced: Option<(Option<String>, Option<String>)> = match d.replaces {
        Some(n) => opt(
            tx.query_row("select author, task from decision where n = ?1", [n], |r| {
                Ok((r.get(0)?, r.get(1)?))
            }),
        )?,
        None => None,
    };
    let own_replace = d.replaces.is_none()
        || replaced
            .as_ref()
            .is_some_and(|(a, t)| a.as_deref() == Some(d.author.as_str()) && *t == d.task);
    let status = if user || (own && own_replace) {
        "current"
    } else {
        "proposed"
    };
    let v = meta::bump_version(tx)?;
    tx.execute(
        "insert into decision (kind, subject, task, paths, reason, author, status, replaces, at, ver, job) \
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        (
            &d.kind,
            &d.subject,
            &d.task,
            &d.paths,
            &d.reason,
            &d.author,
            status,
            d.replaces,
            now,
            v as i64,
            &d.job,
        ),
    )?;
    let n = tx.last_insert_rowid(); // before any other insert
    event(
        tx,
        Event {
            at: now,
            agent: Some(d.author.clone()),
            job: d.job.clone(),
            task: d.task.clone(),
            kind: EventKind::Decision,
            summary: format!("#{n} {}: {} ({status})", d.kind, d.subject),
            data: Some(json!({"n": n, "kind": d.kind, "status": status, "version": v})),
            turn: false,
        },
    )?;
    if let (Some(replaces), "current") = (d.replaces, status) {
        tx.execute(
            "update decision set status = 'replaced', ver = ?1 where n = ?2",
            (v as i64, replaces),
        )?;
    }
    // its author knows it: not told of it as news (it read the log at SEEN, the one before)
    if !user && d.seen.is_some_and(|s| s + 1 == v) {
        meta::set_seen(tx, &d.author, v)?;
    }
    Ok(DecideResult::Ok {
        n,
        status: status.to_string(),
        version: v,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    fn db() -> urdr::Connection {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        c
    }

    fn d(author: &str, seen: Option<u64>) -> Decide {
        Decide {
            kind: "build".into(),
            subject: "x".into(),
            author: author.into(),
            seen,
            ..Decide::default()
        }
    }

    #[test]
    fn a_future_seen_is_refused_and_an_old_one_is_held() {
        let c = db();
        assert!(matches!(
            held_check(&c, Some(3)),
            Err(CoordError::Refused(_))
        ));
        decide(&c, d("user", None), 1.0).unwrap();
        let h = held_check(&c, Some(0)).unwrap().unwrap();
        assert_eq!((h.version, h.changes.len()), (1, 1));
        assert_eq!(held_check(&c, Some(1)).unwrap(), None);
        assert_eq!(held_check(&c, None).unwrap(), None);
    }

    #[test]
    fn the_rate_is_six_a_minute_per_agent() {
        let c = db();
        for _ in 0..DECISION_RATE {
            assert!(matches!(
                decide(&c, d("a1", None), 100.0).unwrap(),
                DecideResult::Ok { .. }
            ));
        }
        assert!(matches!(
            decide(&c, d("a1", None), 101.0).unwrap(),
            DecideResult::Error(_)
        ));
        assert!(matches!(
            decide(&c, d("a1", None), 200.0).unwrap(),
            DecideResult::Ok { .. }
        ));
    }
}

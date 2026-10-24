//! The exec writer (agent system part 1, Task 4): a job (a command the hub runs for an agent or the user) is an
//! entity of kind `exec`, id `exec:<prefix>-<5 base36>`, status `running` until [`finish`].  A session or task that
//! waits on it has a `waits_on` link to it (made by the waiter's own writer, checked by [`crate::kinds`]).

use crate::store::{CoordError, WTx};
use serde_json::{Value, json};
use urdr::graph::entity::{self, Changes, EntityNew, Origin};

/// The statuses an exec ends in.
pub const END_STATUSES: &[&str] = &["done", "stopped", "timed-out", "lost"];

/// A job that starts.
#[derive(Clone, Debug, PartialEq)]
pub struct ExecNew {
    /// The project entity's `n`.
    pub project: Option<i64>,
    /// The session that started it (none: the user).
    pub starter: Option<String>,
    pub argv: Vec<String>,
    pub cwd: String,
    /// `cargo`, `ert`, `domr`, `other` or `container`.
    pub kind: String,
    pub timebox_s: i64,
    /// Seconds since the epoch.
    pub started: f64,
}

/// How a job ended.
#[derive(Clone, Debug, PartialEq)]
pub struct ExecEnd {
    /// One of [`END_STATUSES`].
    pub status: String,
    pub exit: Option<i32>,
    pub ended: f64,
    /// The summary the hub kept (`{exit, failing, lines, log}`).
    pub summary: Option<Value>,
}

/// Make the job; answers its id.
pub fn create(tx: &mut WTx<'_>, new: ExecNew) -> Result<String, CoordError> {
    if new.argv.is_empty() {
        return Err(CoordError::Refused("a job needs a command".into()));
    }
    let id = crate::tracker::new_id(tx, "exec", new.project)?;
    let title: String = new.argv.join(" ").chars().take(200).collect();
    entity::create(
        tx,
        EntityNew {
            id: id.clone(),
            kind: "exec".into(),
            project: new.project,
            title: Some(title),
            status: Some("running".into()),
            body: None,
            priority: None,
            assignee: new.starter.clone(),
            data: json!({"argv": new.argv, "cwd": new.cwd, "kind": new.kind, "timebox_s": new.timebox_s,
                "starter": new.starter, "started": new.started}),
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    Ok(id)
}

/// End job ID.  A job that has ended, or none, is refused.
pub fn finish(tx: &mut WTx<'_>, id: &str, end: ExecEnd) -> Result<(), CoordError> {
    if !END_STATUSES.contains(&end.status.as_str()) {
        return Err(CoordError::Refused(format!(
            "{} is not an end status ({})",
            end.status,
            END_STATUSES.join(", ")
        )));
    }
    let e = entity::by_id(tx.sql(), id)?
        .filter(|e| e.kind == "exec" && e.retired_tx.is_none())
        .ok_or_else(|| CoordError::Refused(format!("no job {id}")))?;
    if e.status.as_deref() != Some("running") {
        return Err(CoordError::Refused(format!(
            "{id} is {}, not running",
            e.status.as_deref().unwrap_or("")
        )));
    }
    entity::update(
        tx,
        e.n,
        None,
        Changes {
            status: Some(Some(end.status)),
            data_patch: Some(json!({"exit": end.exit, "ended": end.ended, "summary": end.summary})),
            ..Changes::default()
        },
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read::exec::get;
    use crate::store::tests::{db7, tx_of};

    fn new() -> ExecNew {
        ExecNew {
            project: None,
            starter: Some("s1".into()),
            argv: vec!["cargo".into(), "test".into()],
            cwd: "/w".into(),
            kind: "cargo".into(),
            timebox_s: 3600,
            started: 10.0,
        }
    }

    #[test]
    fn a_job_runs_then_ends_once() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let id = create(&mut tx, new()).unwrap();
        assert!(id.starts_with("exec:"));
        let j = get(tx.sql(), &id).unwrap().unwrap();
        assert_eq!(
            (j.status.as_str(), j.argv.len(), j.exit),
            ("running", 2, None)
        );
        assert!(
            create(
                &mut tx,
                ExecNew {
                    argv: vec![],
                    ..new()
                }
            )
            .is_err()
        );
        let end = ExecEnd {
            status: "done".into(),
            exit: Some(1),
            ended: 12.0,
            summary: Some(json!({"failing": ["a"]})),
        };
        finish(&mut tx, &id, end.clone()).unwrap();
        let j = get(tx.sql(), &id).unwrap().unwrap();
        assert_eq!(
            (j.status.as_str(), j.exit, j.ended),
            ("done", Some(1), Some(12.0))
        );
        assert_eq!(j.summary, Some(json!({"failing": ["a"]})));
        assert!(finish(&mut tx, &id, end).is_err());
        let bad = ExecEnd {
            status: "running".into(),
            exit: None,
            ended: 1.0,
            summary: None,
        };
        assert!(finish(&mut tx, &id, bad).is_err());
    }

    #[test]
    fn a_session_waits_on_a_job() {
        use urdr::graph::link;
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let id = create(&mut tx, new()).unwrap();
        let ex = entity::by_id(tx.sql(), &id).unwrap().unwrap();
        let s = entity::create(
            &mut tx,
            EntityNew {
                id: "session:s1".into(),
                kind: "session".into(),
                project: None,
                title: None,
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
        assert!(crate::kinds::link_allowed("waits_on", "session", "exec"));
        link::add(&mut tx, s.n, "waits_on", ex.n, None, Origin::Recorded, None).unwrap();
    }
}

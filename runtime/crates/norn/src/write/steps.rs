//! The step writer (agent system part 1, Task 4): one row of the `step` table per unit of an agent's timeline.
//! [`open`] starts a step and gives it the session's next `seq`; [`close`] ends it and adds what it cost.

use crate::store::{CoordError, WTx};
use std::fmt;

/// What a step was spent on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum StepClass {
    Think,
    Tool,
    JobWait,
    MachineQueue,
    UserWait,
    Paused,
    Stalled,
}

impl StepClass {
    pub const ALL: [StepClass; 7] = [
        StepClass::Think,
        StepClass::Tool,
        StepClass::JobWait,
        StepClass::MachineQueue,
        StepClass::UserWait,
        StepClass::Paused,
        StepClass::Stalled,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            StepClass::Think => "think",
            StepClass::Tool => "tool",
            StepClass::JobWait => "job-wait",
            StepClass::MachineQueue => "machine-queue",
            StepClass::UserWait => "user-wait",
            StepClass::Paused => "paused",
            StepClass::Stalled => "stalled",
        }
    }

    pub fn parse(text: &str) -> Option<StepClass> {
        StepClass::ALL.into_iter().find(|c| c.as_str() == text)
    }
}

impl fmt::Display for StepClass {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A step that starts.  `session`, `task`, `plan` and `project` are entity ids.
#[derive(Clone, Debug, PartialEq)]
pub struct StepNew {
    pub session: String,
    pub task: Option<String>,
    pub plan: Option<String>,
    pub project: Option<String>,
    pub agent: Option<String>,
    pub provider: Option<String>,
    pub class: StepClass,
    /// Seconds since the epoch.
    pub start: f64,
    pub tool: Option<String>,
    pub tool_kind: Option<String>,
    pub message_id: Option<String>,
    pub turn_id: Option<String>,
    pub snapshot: Option<String>,
    pub log_version: Option<i64>,
}

/// How a step ended.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StepEnd {
    pub end: f64,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub cost: Option<f64>,
    pub cost_unit: Option<String>,
    /// Set when the step's end has a snapshot or decision log version the start did not.
    pub snapshot: Option<String>,
    pub log_version: Option<i64>,
}

/// Start a step; answers its id.  Its `seq` is the session's next.
pub fn open(tx: &WTx<'_>, new: StepNew) -> Result<i64, CoordError> {
    if new.session.is_empty() {
        return Err(CoordError::Refused("a step needs a session".into()));
    }
    let seq: i64 = tx.sql().query_row(
        "select coalesce(max(seq), 0) + 1 from step where session = ?1",
        [&new.session],
        |r| r.get(0),
    )?;
    tx.sql().execute(
        "insert into step (session, task, plan, project, agent, provider, seq, class, start, tool, tool_kind, \
         message_id, turn_id, snapshot, log_version) \
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
        (
            &new.session,
            &new.task,
            &new.plan,
            &new.project,
            &new.agent,
            &new.provider,
            seq,
            new.class.as_str(),
            new.start,
            &new.tool,
            &new.tool_kind,
            &new.message_id,
            &new.turn_id,
            &new.snapshot,
            new.log_version,
        ),
    )?;
    Ok(tx.sql().last_insert_rowid())
}

/// End step ID.  A step already closed, or none, is refused.
pub fn close(tx: &WTx<'_>, id: i64, end: StepEnd) -> Result<(), CoordError> {
    let changed = tx.sql().execute(
        "update step set end = ?2, tokens_in = ?3, tokens_out = ?4, cache_read = ?5, cache_write = ?6, \
         cost = ?7, cost_unit = ?8, snapshot = coalesce(?9, snapshot), log_version = coalesce(?10, log_version) \
         where id = ?1 and end is null",
        (
            id,
            end.end,
            end.tokens_in,
            end.tokens_out,
            end.cache_read,
            end.cache_write,
            end.cost,
            &end.cost_unit,
            &end.snapshot,
            end.log_version,
        ),
    )?;
    if changed == 0 {
        return Err(CoordError::Refused(format!(
            "step {id} is not open (none, or already closed)"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read::steps::{Rollup, Scope, for_session, rollup};
    use crate::store::tests::{db7, tx_of};

    pub(crate) fn new(session: &str, task: &str, class: StepClass, start: f64) -> StepNew {
        StepNew {
            session: session.into(),
            task: Some(task.into()),
            plan: Some("plan:p".into()),
            project: Some("project:q".into()),
            agent: Some("a1".into()),
            provider: Some("claude".into()),
            class,
            start,
            tool: None,
            tool_kind: None,
            message_id: Some("m1".into()),
            turn_id: Some("t1".into()),
            snapshot: None,
            log_version: Some(3),
        }
    }

    fn end(at: f64, tin: i64, cost: Option<(f64, &str)>) -> StepEnd {
        StepEnd {
            end: at,
            tokens_in: tin,
            tokens_out: 1,
            cost: cost.map(|c| c.0),
            cost_unit: cost.map(|c| c.1.to_string()),
            ..StepEnd::default()
        }
    }

    #[test]
    fn step_rollup_sums_by_class_and_unit() {
        let mut c = db7();
        let tx = tx_of(&mut c);
        let a = open(&tx, new("s1", "task:a", StepClass::Think, 0.0)).unwrap();
        close(&tx, a, end(4.0, 10, Some((0.5, "usd")))).unwrap();
        let b = open(&tx, new("s1", "task:a", StepClass::Think, 4.0)).unwrap();
        close(&tx, b, end(5.5, 5, Some((0.25, "usd")))).unwrap();
        let t = open(&tx, new("s1", "task:a", StepClass::Tool, 5.5)).unwrap();
        close(&tx, t, end(6.0, 0, Some((2.0, "limit-share")))).unwrap();
        // another session, same task, and a step of another task
        let o = open(&tx, new("s2", "task:a", StepClass::JobWait, 0.0)).unwrap();
        close(&tx, o, end(10.0, 0, None)).unwrap();
        let x = open(&tx, new("s3", "task:b", StepClass::Think, 0.0)).unwrap();
        close(&tx, x, end(100.0, 1, None)).unwrap();
        // an open step counts no seconds
        open(&tx, new("s1", "task:a", StepClass::UserWait, 6.0)).unwrap();

        let r = rollup(tx.sql(), Scope::Task, "task:a").unwrap();
        assert_eq!(r.secs_by_class["think"], 5.5);
        assert_eq!(r.secs_by_class["tool"], 0.5);
        assert_eq!(r.secs_by_class["job-wait"], 10.0);
        assert!(!r.secs_by_class.contains_key("user-wait"));
        assert_eq!(r.cost_by_unit["usd"], 0.75);
        assert_eq!(r.cost_by_unit["limit-share"], 2.0);
        assert_eq!((r.tokens.input, r.tokens.output), (15, 4));
        let s = rollup(tx.sql(), Scope::Session, "s1").unwrap();
        assert_eq!(s.secs_by_class.values().sum::<f64>(), 6.0);
        assert_eq!(
            rollup(tx.sql(), Scope::Plan, "plan:p")
                .unwrap()
                .tokens
                .input,
            16
        );
        assert_eq!(
            rollup(tx.sql(), Scope::Project, "project:none").unwrap(),
            Rollup::default()
        );
    }

    #[test]
    fn seq_counts_per_session_and_close_is_once() {
        let mut c = db7();
        let tx = tx_of(&mut c);
        let a = open(&tx, new("s1", "task:a", StepClass::Think, 0.0)).unwrap();
        let b = open(&tx, new("s1", "task:a", StepClass::Tool, 1.0)).unwrap();
        let o = open(&tx, new("s2", "task:a", StepClass::Think, 1.0)).unwrap();
        close(&tx, a, end(1.0, 0, None)).unwrap();
        assert!(close(&tx, a, end(2.0, 0, None)).is_err());
        assert!(close(&tx, 999, end(2.0, 0, None)).is_err());
        let _ = (b, o);
        let all = for_session(tx.sql(), "s1", 0).unwrap();
        assert_eq!(all.iter().map(|s| s.seq).collect::<Vec<_>>(), [1, 2]);
        assert_eq!(all[0].class, StepClass::Think);
        assert_eq!(all[0].end, Some(1.0));
        assert_eq!(all[1].end, None);
        assert_eq!(for_session(tx.sql(), "s1", 1).unwrap().len(), 1);
        assert_eq!(for_session(tx.sql(), "s2", 0).unwrap()[0].seq, 1);
    }
}

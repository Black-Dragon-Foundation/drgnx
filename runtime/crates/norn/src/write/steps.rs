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
    /// The agent conversation (ACP session id) the step ran in: a session can run several, one after a revert.
    pub acp: Option<String>,
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
    /// The session's context size in tokens when the step closed (a turn's last step, a job wait).
    pub context: Option<i64>,
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
         message_id, turn_id, snapshot, log_version, acp) \
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
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
            &new.acp,
        ),
    )?;
    Ok(tx.sql().last_insert_rowid())
}

/// End step ID.  A step already closed, or none, is refused.
pub fn close(tx: &WTx<'_>, id: i64, end: StepEnd) -> Result<(), CoordError> {
    let changed = tx.sql().execute(
        "update step set end = ?2, tokens_in = ?3, tokens_out = ?4, cache_read = ?5, cache_write = ?6, \
         cost = ?7, cost_unit = ?8, snapshot = coalesce(?9, snapshot), log_version = coalesce(?10, log_version), \
         context = ?11 where id = ?1 and end is null",
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
            end.context,
        ),
    )?;
    if changed == 0 {
        return Err(CoordError::Refused(format!(
            "step {id} is not open (none, or already closed)"
        )));
    }
    Ok(())
}

/// Record HEAD, the worktree's commit when step ID's snapshot was taken (an object id read from ref files).
pub fn set_head(tx: &WTx<'_>, id: i64, head: &str) -> Result<(), CoordError> {
    let n = tx
        .sql()
        .execute("update step set head = ?2 where id = ?1", (id, head))?;
    found(n, id)
}

/// Record OP, the edit history's record step ID anchors.
pub fn set_history_op(tx: &WTx<'_>, id: i64, op: i64) -> Result<(), CoordError> {
    let n = tx
        .sql()
        .execute("update step set history_op = ?2 where id = ?1", (id, op))?;
    found(n, id)
}

fn found(changed: usize, id: i64) -> Result<(), CoordError> {
    if changed == 0 {
        return Err(CoordError::Refused(format!("no step {id}")));
    }
    Ok(())
}

/// Mark SESSION's steps after AFTER_SEQ as abandoned by the revert record OP; a step an earlier revert marked keeps
/// its mark.  Answers how many were marked.
pub fn mark_undone(
    tx: &WTx<'_>,
    session: &str,
    after_seq: i64,
    op: i64,
) -> Result<usize, CoordError> {
    Ok(tx.sql().execute(
        "update step set undone_by = ?3 where session = ?1 and seq > ?2 and undone_by is null",
        (session, after_seq, op),
    )?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read::steps::{Rollup, Scope, for_session, rollup};
    use crate::store::tests::{db7, tx_of};

    /// Pure (D): the gateway's charge is exact dollars beside the agents' estimates.
    #[test]
    fn a_gateway_tasks_rollup_shows_exact_dollars() {
        use crate::write::spend::{SpendRow, add_spend};
        let mut c = db7();
        let tx = tx_of(&mut c);
        for (id, plan) in [
            ("J", Some("plan:ab-1")),
            ("K", Some("/p/x.md")),
            ("L", None),
        ] {
            tx.sql()
                .execute(
                    "insert into job (id, title, plan, status, created) values (?1, 't', ?2, 'running', 1.0)",
                    (id, plan),
                )
                .unwrap();
        }
        let row = |job: &str, task: &str, cost: f64| SpendRow {
            job: Some(job.into()),
            task: Some(task.into()),
            provider: "openrouter".into(),
            cost,
            status: 200,
            ..SpendRow::default()
        };
        add_spend(&tx, &row("J", "J#1", 1.5), 1.0).unwrap();
        add_spend(&tx, &row("J", "J#1", 0.5), 2.0).unwrap();
        add_spend(&tx, &row("J", "J#2", 4.0), 3.0).unwrap();
        add_spend(&tx, &row("K", "K#1", 8.0), 4.0).unwrap();
        add_spend(&tx, &row("L", "L#1", 16.0), 5.0).unwrap();
        let t = rollup(tx.sql(), Scope::Task, "J#1").unwrap();
        assert_eq!(t.cost_by_unit["usd"], 2.0);
        let plan = |s: &str| rollup(tx.sql(), Scope::Plan, s).unwrap().cost_by_unit;
        assert_eq!(plan("plan:ab-1")["usd"], 6.0);
        assert_eq!(plan("plan:/p/x.md")["usd"], 8.0);
        assert_eq!(plan("plan:L")["usd"], 16.0);
        assert!(!plan("plan:none").contains_key("usd"));
    }

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
            acp: Some("acp-1".into()),
        }
    }

    /// Pattern D: a revert marks the session's steps after its point; the steps before it, another session's, and the
    /// ones an earlier revert marked keep theirs.
    #[test]
    fn mark_undone_marks_only_after_seq() {
        let mut c = db7();
        let tx = tx_of(&mut c);
        for i in 0..4 {
            open(&tx, new("s1", "task:a", StepClass::Tool, f64::from(i))).unwrap();
        }
        open(&tx, new("s2", "task:a", StepClass::Tool, 0.0)).unwrap();
        assert_eq!(mark_undone(&tx, "s1", 2, 77).unwrap(), 2);
        // a second revert, to a point before the first
        assert_eq!(mark_undone(&tx, "s1", 1, 78).unwrap(), 1);
        assert_eq!(mark_undone(&tx, "s1", 4, 79).unwrap(), 0);
        let marks: Vec<(String, i64, Option<i64>)> = tx
            .sql()
            .prepare("select session, seq, undone_by from step order by session, seq")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(
            marks,
            [
                ("s1".into(), 1, None),
                ("s1".into(), 2, Some(78)),
                ("s1".into(), 3, Some(77)),
                ("s1".into(), 4, Some(77)),
                ("s2".into(), 1, None),
            ]
        );
        // the conversation, the head and the history record read back
        let all = for_session(tx.sql(), "s1", 0).unwrap();
        assert_eq!(all[0].acp.as_deref(), Some("acp-1"));
        set_head(&tx, all[0].id, "0123456789abcdef0123456789abcdef01234567").unwrap();
        set_history_op(&tx, all[0].id, 5).unwrap();
        let s = &for_session(tx.sql(), "s1", 0).unwrap()[0];
        assert_eq!(
            (s.head.as_deref(), s.history_op, s.undone_by),
            (
                Some("0123456789abcdef0123456789abcdef01234567"),
                Some(5),
                None
            )
        );
        assert_eq!(
            for_session(tx.sql(), "s1", 0).unwrap()[1].undone_by,
            Some(78)
        );
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

//! The agent registry writers (Task 5): `drgnx-coord-agent-register` and `drgnx-coord-agent-seen`
//! (`core/drgnx-coord.el`).

use crate::store::{CoordDb, CoordError, WTx};
use urdr::graph::TxMeta;

/// The fields `clear` may set to NULL (`:kind :name :cwd :worktree :branch :base :plan :task :pid`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentField {
    Kind,
    Name,
    Cwd,
    Worktree,
    Branch,
    Base,
    Plan,
    Task,
    Pid,
}

impl AgentField {
    pub fn column(self) -> &'static str {
        match self {
            AgentField::Kind => "kind",
            AgentField::Name => "name",
            AgentField::Cwd => "cwd",
            AgentField::Worktree => "worktree",
            AgentField::Branch => "branch",
            AgentField::Base => "base",
            AgentField::Plan => "plan",
            AgentField::Task => "task",
            AgentField::Pid => "pid",
        }
    }

    pub fn parse(name: &str) -> Option<AgentField> {
        [
            AgentField::Kind,
            AgentField::Name,
            AgentField::Cwd,
            AgentField::Worktree,
            AgentField::Branch,
            AgentField::Base,
            AgentField::Plan,
            AgentField::Task,
            AgentField::Pid,
        ]
        .into_iter()
        .find(|f| f.column() == name)
    }
}

/// What `agent_register` takes: a given field is stored, an omitted one is kept.
#[derive(Debug, Clone, Default)]
pub struct AgentRegister {
    pub id: String,
    pub kind: Option<String>,
    pub name: Option<String>,
    pub cwd: Option<String>,
    pub worktree: Option<String>,
    pub branch: Option<String>,
    pub base: Option<String>,
    pub plan: Option<String>,
    pub task: Option<String>,
    pub pid: Option<i64>,
    /// Fields to set to NULL (after the upsert); an omitted field above means "keep".
    pub clear: Vec<AgentField>,
}

/// `drgnx-coord-agent-register`: note that agent `id` works (again): what is given is stored, what is not is kept,
/// and when it started is kept.  The id.
pub fn agent_register(tx: &mut WTx<'_>, a: AgentRegister, now: f64) -> Result<String, CoordError> {
    if a.id.is_empty() {
        return Err(CoordError::Refused("An agent needs an id".into()));
    }
    let by = tx.id();
    tx.sql().execute(
        "insert into agent (id, kind, name, cwd, worktree, branch, base, plan, task, pid, started, seen, tx)
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
         on conflict (id) do update set kind = coalesce(excluded.kind, kind),
         name = coalesce(excluded.name, name), cwd = coalesce(excluded.cwd, cwd),
         worktree = coalesce(excluded.worktree, worktree), branch = coalesce(excluded.branch, branch),
         base = coalesce(excluded.base, base), plan = coalesce(excluded.plan, plan),
         task = coalesce(excluded.task, task), pid = coalesce(excluded.pid, pid), seen = excluded.seen,
         tx = excluded.tx",
        (
            &a.id, &a.kind, &a.name, &a.cwd, &a.worktree, &a.branch, &a.base, &a.plan, &a.task,
            a.pid, now, now, by,
        ),
    )?;
    for f in &a.clear {
        tx.sql().execute(
            &format!("update agent set {} = null where id = ?1", f.column()),
            [&a.id],
        )?;
    }
    Ok(a.id)
}

/// `drgnx-coord-agent-seen`: agent `id` is alive now: stamp it.  The stamp, or `None` (nothing written) when the
/// agent was never registered.
pub fn agent_seen(tx: &mut WTx<'_>, id: &str, now: f64) -> Result<Option<f64>, CoordError> {
    let by = tx.id();
    let n = tx.sql().execute(
        "update agent set seen = ?1, tx = ?3 where id = ?2",
        (now, id, by),
    )?;
    Ok((n > 0).then_some(now))
}

/// `agent_seen` as telemetry: in a transaction of its own (by META's author), `None` (not an error) when the
/// database stays busy.
pub async fn agent_seen_best_effort(
    db: &CoordDb,
    meta: TxMeta,
    id: String,
    now: f64,
) -> Result<Option<f64>, CoordError> {
    match db.write(meta, move |tx| agent_seen(tx, &id, now)).await {
        Err(CoordError::Busy) => Ok(None),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read::agents::agent;
    use crate::store::tests::{db7, tx_of};

    fn reg(id: &str) -> AgentRegister {
        AgentRegister {
            id: id.into(),
            ..AgentRegister::default()
        }
    }

    #[test]
    fn registering_twice_keeps_what_is_not_given_and_clear_nulls_it() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let first = AgentRegister {
            kind: Some("claude".into()),
            worktree: Some("/w".into()),
            pid: Some(42),
            ..reg("a")
        };
        agent_register(&mut tx, first, 10.0).unwrap();
        let second = AgentRegister {
            branch: Some("b".into()),
            clear: vec![AgentField::Worktree],
            ..reg("a")
        };
        agent_register(&mut tx, second, 20.0).unwrap();
        let a = agent(tx.sql(), "a").unwrap().unwrap();
        assert_eq!(a.kind.as_deref(), Some("claude"));
        assert_eq!(a.branch.as_deref(), Some("b"));
        assert_eq!(a.worktree, None);
        assert_eq!(a.pid, Some(42));
        assert_eq!((a.started, a.seen), (Some(10.0), Some(20.0)));
        assert!(agent_register(&mut tx, reg(""), 1.0).is_err());
        assert_eq!(agent_seen(&mut tx, "a", 30.0).unwrap(), Some(30.0));
        assert_eq!(agent_seen(&mut tx, "nobody", 30.0).unwrap(), None);
    }
}

//! `work.db` schema 7 → 8 (agent system part 1, Task 4): the `step` table, one row per unit of an agent's timeline
//! (a thought run, a tool call, a wait).  The new entity kinds (`exec`, `report`, `proposal`), the status `waiting`
//! and the new links are code lists ([`crate::kinds`], [`crate::tracker`]) and need no rows.
//!
//! The move is one `BEGIN IMMEDIATE` transaction that adds the table and its indexes and sets `schema = 8`, so a
//! crash leaves schema 7 as it was.  A fresh file and a schema-6 file are made or migrated to 7 first
//! ([`crate::migrate7`]) and then moved here by the same opening rule.  Rows are never rewritten: the move keeps
//! every row of every table.

use urdr::Connection;

/// The schema this module makes.
pub const SCHEMA: u32 = 8;

/// The step table.  `session`, `task`, `plan` and `project` are entity ids (text), so a step survives the
/// entity's version changes; `seq` counts a session's steps from 1; `start` and `end` are seconds since the epoch
/// (`end` null while the step runs); `class` is one of `think tool job-wait machine-queue user-wait paused stalled`.
pub const STEP_DDL: &str = "
create table step (
  id integer primary key,
  session text not null,
  task text, plan text, project text,
  agent text, provider text,
  seq integer not null,
  class text not null,
  start real not null,
  end real,
  tool text, tool_kind text,
  message_id text, turn_id text,
  snapshot text,
  log_version integer,
  tokens_in integer not null default 0, tokens_out integer not null default 0,
  cache_read integer not null default 0, cache_write integer not null default 0,
  cost real, cost_unit text);
create unique index step_session on step(session, seq);
create index step_task on step(task) where task is not null;
create index step_plan on step(plan) where plan is not null;
create index step_project on step(project) where project is not null;";

/// Add the step table to the schema-7 file on CONN, in one transaction; `Ok(false)` when the file is not schema 7
/// when the transaction holds the lock (another process moved it, or it is another schema): nothing is done.
pub fn upgrade(conn: &mut Connection) -> Result<bool, urdr::SqliteError> {
    conn.execute_batch("begin immediate")?;
    let out = (|| {
        let schema: Option<String> = conn
            .query_row("select value from kv where key = 'schema'", [], |r| {
                r.get(0)
            })
            .map(Some)
            .or_else(|e| match e {
                urdr::SqliteError::QueryReturnedNoRows => Ok(None),
                e => Err(e),
            })?;
        if schema.as_deref().map(str::trim) != Some("7") {
            return Ok(false);
        }
        conn.execute_batch(STEP_DDL)?;
        conn.execute(
            "insert or replace into kv (key, value) values ('schema', ?1)",
            [SCHEMA.to_string()],
        )?;
        Ok(true)
    })();
    match out {
        Ok(done) => {
            conn.execute_batch("commit").inspect_err(|_| {
                let _ = conn.execute_batch("rollback");
            })?;
            Ok(done)
        }
        Err(e) => {
            let _ = conn.execute_batch("rollback");
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::{db7_only, tx_of};
    use urdr::graph::entity::{self, EntityNew, Origin};

    fn counts(c: &Connection) -> Vec<(String, i64)> {
        let names: Vec<String> = {
            let mut st = c
                .prepare("select name from sqlite_master where type = 'table' and name not like '%fts%' and name not like 'sqlite_%' and name <> 'step' order by name")
                .unwrap();
            st.query_map([], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        names
            .into_iter()
            .map(|n| {
                let k = c
                    .query_row(&format!("select count(*) from \"{n}\""), [], |r| r.get(0))
                    .unwrap();
                (n, k)
            })
            .collect()
    }

    /// A schema-7 file with rows in the graph, the coordination tables and `kv`; the move keeps all of them.
    #[test]
    fn migration_7_to_8_keeps_every_row() {
        let mut c = db7_only();
        {
            let mut tx = tx_of(&mut c);
            for (i, kind) in ["task", "decision", "note", "spec"].into_iter().enumerate() {
                entity::create(
                    &mut tx,
                    EntityNew {
                        id: format!("{kind}:k{i}"),
                        kind: kind.into(),
                        project: None,
                        title: Some(format!("t{i}")),
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data: serde_json::json!({}),
                        origin: Origin::Recorded,
                        source: None,
                    },
                )
                .unwrap();
            }
            tx.sql()
                .execute_batch(
                    "insert into message (sender, recipient, text, state, at) values ('a', 'b', 'hi', 'queued', 1);
                     insert into card (kind, title, data, state, at) values ('ask', 'q', '{}', 'open', 1);
                     insert into event (at, kind, summary) values (1, 'note', 's');
                     insert into spend (at, provider, input, output, cost, status) values (1, 'p', 1, 2, 0.5, 200);",
                )
                .unwrap();
            tx.commit_for_test().unwrap();
        }
        let before = counts(&c);
        assert!(
            before.iter().any(|(n, k)| n == "entity" && *k == 4),
            "{before:?}"
        );
        let kv: Vec<(String, String)> = {
            let mut st = c.prepare("select key, value from kv order by key").unwrap();
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert!(upgrade(&mut c).unwrap());
        assert_eq!(counts(&c), before);
        let after: Vec<(String, String)> = {
            let mut st = c.prepare("select key, value from kv order by key").unwrap();
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        let mut expect = kv;
        for (k, v) in &mut expect {
            if k == "schema" {
                *v = "8".into();
            }
        }
        assert_eq!(after, expect);
        let steps: i64 = c
            .query_row("select count(*) from step", [], |r| r.get(0))
            .unwrap();
        assert_eq!(steps, 0);
        // a second move does nothing
        assert!(!upgrade(&mut c).unwrap());
    }
}

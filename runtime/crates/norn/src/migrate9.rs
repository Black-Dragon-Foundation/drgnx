//! `work.db` schema 8 → 9 (agent system part 2, the Work space): the hub's facts the map reads.  `step_detail`
//! (what a timeline step read, searched or fetched), `worktree_base` (where a worktree branched from), and the
//! `decision` view's `sources` column (the files and pages a conclusion names).  The new entity kind `ask` and
//! the link `asked` are code lists ([`crate::kinds`]) and need no rows.
//!
//! A decision is an entity read through the `decision` view, so `sources` is a key of the entity's `data` and the
//! move recreates the view with the column; the writer checks the shape and the count, since a view takes no
//! `check`.  The move is one `BEGIN IMMEDIATE` transaction that adds the tables and the view and sets
//! `schema = 9`, so a crash leaves schema 8 as it was.  Rows are never rewritten.

use urdr::Connection;
use urdr::graph::schema::SENTINEL;

/// The schema this module makes.
pub const SCHEMA: u32 = 9;

/// `origin` of a `step_detail` row: how the hub learned it.
pub const ORIGINS: [&str; 5] = ["acp", "acp-title", "browser", "command", "opened"];

/// The two tables.  `step` is a timeline step's id; `repo`, `worktree` and the base fields are paths and git ids;
/// `at` is seconds since the epoch.
pub const TABLES_DDL: &str = "
create table step_detail (
  step integer primary key references step(id),
  tool text, kind text, path text, line_start integer, line_end integer,
  query text, url text, title text,
  origin text not null check (origin in ('acp', 'acp-title', 'browser', 'command', 'opened')));
create table worktree_base (
  worktree text primary key,
  repo text not null,
  base_branch text, base_commit text, base_tree text,
  at real not null);";

/// The `decision` view as schema 7 made it, with `sources` last.
fn decision_view() -> String {
    format!(
        "
drop view decision;
create view decision as
select json_extract(e.data, '$.n') as n,
  json_extract(e.data, '$.kind') as kind,
  e.title as subject,
  json_extract(e.data, '$.task') as task,
  json_extract(e.data, '$.paths') as paths,
  e.body as reason,
  json_extract(e.data, '$.author') as author,
  e.status as status,
  coalesce((select json_extract(o.data, '$.n') from link l join entity o on o.n = l.dst
            where l.src = e.n and l.kind = 'supersedes' and l.tx_to = {SENTINEL}),
           json_extract(e.data, '$.replaces')) as replaces,
  json_extract(e.data, '$.at') as at,
  json_extract(e.data, '$.ver') as ver,
  json_extract(e.data, '$.job') as job,
  json_extract(e.data, '$.sources') as sources
from entity e
where e.retired_tx is null and e.kind = 'decision';
"
    )
}

/// Move the schema-8 file on CONN to 9, in one transaction; `Ok(false)` when the file is not schema 8 when the
/// transaction holds the lock (another process moved it, or it is another schema): nothing is done.
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
        if schema.as_deref().map(str::trim) != Some("8") {
            return Ok(false);
        }
        conn.execute_batch(TABLES_DDL)?;
        conn.execute_batch(&decision_view())?;
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

    fn tables(c: &Connection) -> Vec<(String, i64)> {
        let names: Vec<String> = {
            let mut st = c
                .prepare("select name from sqlite_master where type = 'table' and name not like '%fts%' and name not like 'sqlite_%' and name not in ('step_detail', 'worktree_base') order by name")
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

    fn kv(c: &Connection) -> Vec<(String, String)> {
        let mut st = c.prepare("select key, value from kv order by key").unwrap();
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }

    /// A schema-8 file with rows in the graph, the coordination tables, a step and `kv`.
    fn db8_with_rows() -> Connection {
        let mut c = db7_only();
        assert!(crate::migrate8::upgrade(&mut c).unwrap());
        {
            let mut tx = tx_of(&mut c);
            for (i, kind) in ["task", "note", "spec"].into_iter().enumerate() {
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
            entity::create(
                &mut tx,
                EntityNew {
                    id: "decision:1".into(),
                    kind: "decision".into(),
                    project: None,
                    title: Some("use x".into()),
                    status: Some("current".into()),
                    body: Some("because".into()),
                    priority: None,
                    assignee: None,
                    data: serde_json::json!({"n": 1, "kind": "choice", "author": "a"}),
                    origin: Origin::Recorded,
                    source: None,
                },
            )
            .unwrap();
            tx.sql()
                .execute_batch(
                    "insert into event (at, kind, summary) values (1, 'note', 's');
                     insert into step (session, seq, class, start) values ('session:s', 1, 'tool', 1.0);",
                )
                .unwrap();
            tx.commit_for_test().unwrap();
        }
        c
    }

    #[test]
    fn upgrade_keeps_rows_and_is_idempotent() {
        let mut c = db8_with_rows();
        let before = tables(&c);
        let decisions: Vec<(i64, String)> = {
            let mut st = c.prepare("select n, subject from decision").unwrap();
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(decisions, [(1, "use x".to_string())]);
        let kv_before = kv(&c);
        assert!(upgrade(&mut c).unwrap());
        assert_eq!(tables(&c), before);
        let mut expect = kv_before;
        for (k, v) in &mut expect {
            if k == "schema" {
                *v = "9".into();
            }
        }
        assert_eq!(kv(&c), expect);
        // the new tables are empty, the view answers the old columns and a null `sources`
        for t in ["step_detail", "worktree_base"] {
            let n: i64 = c
                .query_row(&format!("select count(*) from {t}"), [], |r| r.get(0))
                .unwrap();
            assert_eq!(n, 0, "{t}");
        }
        let row: (i64, String, String, Option<String>) = c
            .query_row(
                "select n, subject, reason, sources from decision",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!(row, (1, "use x".into(), "because".into(), None));
        // a second move does nothing
        assert!(!upgrade(&mut c).unwrap());
        assert_eq!(kv(&c), expect);
    }

    #[test]
    fn a_step_detail_needs_a_known_origin_and_a_step() {
        let mut c = db8_with_rows();
        assert!(upgrade(&mut c).unwrap());
        c.execute_batch("pragma foreign_keys = on").unwrap();
        let ok = c.execute(
            "insert into step_detail (step, tool, origin) values (1, 'Read', 'acp')",
            [],
        );
        assert!(ok.is_ok());
        let bad = c.execute(
            "insert into step_detail (step, tool, origin) values (1, 'Read', 'guess')",
            [],
        );
        assert!(bad.is_err());
    }
}

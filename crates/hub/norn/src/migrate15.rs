//! `work.db` schema 14 → 15: the `node` view lists every task that is no job task (`data.job` empty), the records
//! importer's (`task:rec-…`) with the scanner's (`task:/…`), and a node's `parent` is `data.parent` or, for the
//! importer's pieces, which keep none, the source of the live `parent_of` link into it (a task's plan head).  Schema
//! 7's view took a task by its `task:/` id only, so the importer's plan tasks were in neither `node` nor `jtask`: the
//! editor's Work tab, `drgnx work status` and `drgnx-work-nodes` saw none.
//!
//! The move is one `BEGIN IMMEDIATE` transaction: the view made again, then `schema = 15`.  A crash leaves schema 14
//! as it was.

use urdr::Connection;

/// The schema this module makes.
pub const SCHEMA: u32 = 15;

// The view names a current link by its `tx_to`, spelled out in the DDL.
const _: () = assert!(urdr::graph::schema::SENTINEL == 4_611_686_018_427_387_904);

const DDL: &str = "
drop view node;
create view node as
select e.id as id, e.kind as kind, e.title as title,
  json_extract(e.data, '$.path') as path,
  json_extract(e.data, '$.line') as line,
  e.status as status,
  coalesce(json_extract(e.data, '$.parent'),
           (select p.id from link l join entity p on p.n = l.src
            where l.dst = e.n and l.kind = 'parent_of' and l.tx_to = 4611686018427387904
              and p.retired_tx is null order by l.id limit 1)) as parent,
  json_extract(e.data, '$.ord') as ord,
  e.source as source,
  nullif(json_remove(e.data, '$.path', '$.line', '$.parent', '$.ord'), '{}') as data,
  (select t.at from tx t where t.id = e.updated_tx) as updated
from entity e
where e.retired_tx is null
  and (e.kind in ('spec', 'plan', 'step', 'todo', 'ruling', 'commit', 'branch')
       or (e.kind = 'task' and json_extract(e.data, '$.job') is null));";

/// Move the schema-14 file on CONN to 15, in one transaction; `Ok(false)` when the file is not schema 14 when the
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
        if schema.as_deref().map(str::trim) != Some("14") {
            return Ok(false);
        }
        conn.execute_batch(DDL)?;
        conn.execute(
            "insert or replace into kv (key, value) values ('schema', ?1)",
            [SCHEMA.to_string()],
        )?;
        Ok(true)
    })();
    match out {
        Ok(done) => {
            conn.execute_batch("commit").inspect_err(|_| {
                crate::rollback(conn);
            })?;
            Ok(done)
        }
        Err(e) => {
            crate::rollback(conn);
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::db14;

    fn schema(c: &Connection) -> String {
        c.query_row("select value from kv where key = 'schema'", [], |r| {
            r.get(0)
        })
        .unwrap()
    }

    fn node_ids(c: &Connection) -> Vec<String> {
        let mut q = c.prepare("select id from node order by id").unwrap();
        q.query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    /// Pattern D. A populated schema-14 file: the importer's plan task, missing from `node` before the move, is in it
    /// after, under its plan head, with the scanner's task and the plan; a job task stays out (it is `jtask`'s); a
    /// second move changes nothing.
    #[test]
    fn migrate15_lists_the_importers_tasks_as_nodes() {
        let mut c = db14();
        c.execute_batch(
            "insert into tx (id, at, actor, class) values (1, 1.0, 'hub', 'hub');
             insert into entity (id, kind, title, data, origin, ver, created_tx, updated_tx) values
               ('plan:rec-a-b', 'plan', 'P', '{}', 'parsed', 1, 1, 1),
               ('task:rec-a-c', 'task', '1 one', '{\"number\":\"1\"}', 'parsed', 1, 1, 1),
               ('task:/w/p.md#2', 'task', 'two', '{}', 'parsed', 1, 1, 1),
               ('task:J#1', 'task', 'job one', '{\"job\":\"J\",\"n\":1}', 'agent', 1, 1, 1);
             insert into link (src, kind, dst, origin, tx_from)
               select p.n, 'parent_of', t.n, 'parsed', 1 from entity p, entity t
               where p.id = 'plan:rec-a-b' and t.id = 'task:rec-a-c';",
        )
        .unwrap();
        assert_eq!(
            node_ids(&c),
            ["plan:rec-a-b", "task:/w/p.md#2"],
            "schema 14 misses it"
        );
        assert!(upgrade(&mut c).unwrap());
        assert_eq!(schema(&c), "15");
        assert_eq!(
            node_ids(&c),
            ["plan:rec-a-b", "task:/w/p.md#2", "task:rec-a-c"]
        );
        let parent: String = c
            .query_row(
                "select parent from node where id = 'task:rec-a-c'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(parent, "plan:rec-a-b", "under its plan head");
        let jobs: i64 = c
            .query_row("select count(*) from jtask", [], |r| r.get(0))
            .unwrap();
        assert_eq!(jobs, 1);
        assert!(!upgrade(&mut c).unwrap(), "a second move does nothing");
        assert_eq!(schema(&c), "15");
    }

    /// A crash inside the move (a statement that fails) leaves schema 14.
    #[test]
    fn a_failed_move_leaves_schema_14() {
        let mut c = db14();
        // no view to drop: the move's first statement fails
        c.execute_batch("drop view node").unwrap();
        assert!(upgrade(&mut c).is_err());
        assert_eq!(schema(&c), "14");
    }
}

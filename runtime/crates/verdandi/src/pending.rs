//! A revert's pending record: from the moment its record is written until its last step is done, the caller's JSON
//! (what the steps after a crash need) is kept beside the record in the `pending` table, so the next start finishes
//! it.  And the records a session caused after a time: a revert's scope.

use crate::store::History;
use crate::{OpId, Result};
use rusqlite::params;

impl History {
    /// Keep JSON as record OP's pending revert (replacing one kept before), stamped AT.
    pub fn mark_pending(&mut self, op: OpId, json: &str, at: f64) -> Result<()> {
        self.conn.execute(
            "insert or replace into pending (op, json, at) values (?1, ?2, ?3)",
            params![op.0, json, at],
        )?;
        Ok(())
    }

    /// Record OP's revert is done: its pending record goes.  False when there was none (a step repeated after a crash).
    pub fn clear_pending(&mut self, op: OpId) -> Result<bool> {
        Ok(self
            .conn
            .execute("delete from pending where op = ?1", [op.0])?
            > 0)
    }

    /// Every pending revert, oldest record first.
    pub fn pending(&self) -> Result<Vec<(OpId, String)>> {
        let mut st = self
            .conn
            .prepare("select op, json from pending order by op")?;
        let rows = st
            .query_map([], |r| Ok((OpId(r.get(0)?), r.get(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// The records SESSION caused (`cause.session`) after AT, oldest first.
    pub fn caused_by(&self, session: &str, at: f64) -> Result<Vec<OpId>> {
        let mut st = self.conn.prepare(
            "select id from op where json_extract(cause_json, '$.session') = ?1 and at > ?2 order by id",
        )?;
        let rows = st
            .query_map(params![session, at], |r| Ok(OpId(r.get(0)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }
}

#[cfg(test)]
mod tests {
    use crate::OpId;
    use crate::store::{Cause, History, Kind, Record};

    fn record(h: &mut History, session: Option<&str>, at: f64) -> OpId {
        let p = h.peer(&serde_json::json!({"kind": "user"}), None).unwrap();
        h.record(Record {
            kind: Kind::AgentStep,
            author: p,
            cause: Cause {
                session: session.map(str::to_owned),
                ..Cause::default()
            },
            spans: Vec::new(),
            parents: Vec::new(),
            git: None,
            summary: "s".into(),
            at,
        })
        .unwrap()
    }

    /// Pure store (D): a pending record is kept, replaced, listed and cleared once.
    #[test]
    fn pending_is_kept_until_cleared() {
        let dir = tempfile::tempdir().unwrap();
        let mut h = History::open(dir.path()).unwrap();
        let op = record(&mut h, Some("s1"), 1.0);
        h.mark_pending(op, r#"{"a":1}"#, 2.0).unwrap();
        h.mark_pending(op, r#"{"a":2}"#, 3.0).unwrap();
        assert_eq!(h.pending().unwrap(), [(op, r#"{"a":2}"#.to_string())]);
        assert!(h.clear_pending(op).unwrap());
        assert!(!h.clear_pending(op).unwrap());
        assert!(h.pending().unwrap().is_empty());
    }

    /// Pure store (D): a session's records after a time, and no other's.
    #[test]
    fn caused_by_is_the_sessions_records_after_the_time() {
        let dir = tempfile::tempdir().unwrap();
        let mut h = History::open(dir.path()).unwrap();
        let early = record(&mut h, Some("s1"), 1.0);
        let late = record(&mut h, Some("s1"), 5.0);
        record(&mut h, Some("s2"), 6.0);
        record(&mut h, None, 7.0);
        assert_eq!(h.caused_by("s1", 2.0).unwrap(), [late]);
        assert_eq!(h.caused_by("s1", 0.0).unwrap(), [early, late]);
    }
}

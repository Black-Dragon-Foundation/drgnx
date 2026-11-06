//! A revert's pending record: from the moment its record is written until its last step is done, the caller's JSON
//! (what the steps after a crash need) is kept beside the record in the `pending` table, so the next start finishes
//! it.  The hub's own previews of a revert, kept until applied.  And the records a session caused after a time (a
//! revert's scope) or up to one (a fork's point).

use crate::store::History;
use crate::{BranchId, OpId, Result};
use rusqlite::{OptionalExtension, params};

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

    /// Keep JSON as the caller's preview ID of BRANCH, stamped AT: a preview the caller worked out itself (it has no
    /// frontier, so the store's own `apply_revert` never takes it).  ID is the caller's, unique across its stores.
    pub fn keep_preview(&mut self, id: i64, branch: BranchId, json: &str, at: f64) -> Result<()> {
        self.conn.execute(
            "insert or replace into preview (id, branch, frontier_blob, json, at) values (?1, ?2, x'', ?3, ?4)",
            params![id, branch.0, json, at],
        )?;
        Ok(())
    }

    /// The caller's preview ID, taken (a preview is applied once); none when this store has none by that id.
    pub fn take_preview(&mut self, id: i64) -> Result<Option<String>> {
        let tx = self.conn.transaction()?;
        let json: Option<String> = tx
            .query_row(
                "select json from preview where id = ?1 and length(frontier_blob) = 0",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        if json.is_some() {
            tx.execute("delete from preview where id = ?1", [id])?;
        }
        tx.commit()?;
        Ok(json)
    }

    /// Preview ID of [`History::preview_revert`] dropped unapplied: a caller that only wanted its text.
    pub fn drop_preview(&mut self, id: i64) -> Result<()> {
        self.conn
            .execute("delete from preview where id = ?1", [id])?;
        Ok(())
    }

    /// The newest record SESSION caused at or before AT.
    pub fn last_caused_by(&self, session: &str, at: f64) -> Result<Option<OpId>> {
        Ok(self
            .conn
            .query_row(
                "select id from op where json_extract(cause_json, '$.session') = ?1 and at <= ?2 \
                 order by id desc limit 1",
                params![session, at],
                |r| Ok(OpId(r.get(0)?)),
            )
            .optional()?)
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

    /// Pure store (D): a caller's preview is kept under the id it chose, taken once, and never confused with a
    /// preview of the store's own (`preview_revert`'s, which has a frontier).
    #[test]
    fn a_stored_preview_is_taken_once() {
        let dir = tempfile::tempdir().unwrap();
        let mut h = History::open(dir.path()).unwrap();
        let br = h
            .branch("wt/x", crate::store::BranchKind::Worktree, None)
            .unwrap();
        h.keep_preview(1 << 40, br, r#"{"p":1}"#, 1.0).unwrap();
        assert_eq!(h.take_preview(7).unwrap(), None);
        assert_eq!(
            h.take_preview(1 << 40).unwrap().as_deref(),
            Some(r#"{"p":1}"#)
        );
        assert_eq!(h.take_preview(1 << 40).unwrap(), None);
        // a reopened store holds what was kept before
        h.keep_preview(5, br, "{}", 2.0).unwrap();
        drop(h);
        let mut h = History::open(dir.path()).unwrap();
        assert_eq!(h.take_preview(5).unwrap().as_deref(), Some("{}"));
    }

    /// Pure store (D): the newest record a session caused up to a time.
    #[test]
    fn last_caused_by_is_the_newest_up_to_the_time() {
        let dir = tempfile::tempdir().unwrap();
        let mut h = History::open(dir.path()).unwrap();
        assert_eq!(h.last_caused_by("s1", 9.0).unwrap(), None);
        let early = record(&mut h, Some("s1"), 1.0);
        let at = record(&mut h, Some("s1"), 3.0);
        record(&mut h, Some("s1"), 5.0);
        record(&mut h, Some("s2"), 2.0);
        assert_eq!(h.last_caused_by("s1", 3.0).unwrap(), Some(at));
        assert_eq!(h.last_caused_by("s1", 2.0).unwrap(), Some(early));
        assert_eq!(h.last_caused_by("s1", 0.5).unwrap(), None);
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

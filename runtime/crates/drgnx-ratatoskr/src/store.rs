//! `work.db`, read-only (storage design §9 step 0): the front's reads (`events/since`, the `events` broadcast, the
//! schema tick); its writes go through norn's writer ([`crate::coord`]), the backend's own through the Lisp.  Read
//! through `urdr::open_readonly` on a thread of its own, so SQLite never runs on an async worker.  The file may not exist yet
//! (a fresh install): it is opened the first time it is there, and until then every read says so.

use runstav::methods::hub::{EventRow, EventsPage};
use serde_json::Value;
use std::path::PathBuf;
use tokio::sync::{mpsc, oneshot};

/// `events/since` without a `limit`.
pub const EVENTS_DEFAULT: u64 = 200;
/// The most `events/since` answers at once.
pub const EVENTS_MAX: u64 = 1000;

type Job = Box<dyn FnOnce(Option<&urdr::Connection>) + Send>;

/// The read-only `work.db`; cheap to clone.
#[derive(Clone)]
pub struct WorkDb {
    tx: mpsc::Sender<Job>,
}

impl WorkDb {
    /// The thread for the `work.db` at PATH (which need not exist).  It ends when the last `WorkDb` is dropped.
    pub fn spawn(path: PathBuf) -> std::io::Result<WorkDb> {
        let (tx, mut rx) = mpsc::channel::<Job>(64);
        std::thread::Builder::new()
            .name("work-db".into())
            .spawn(move || {
                let mut conn: Option<urdr::Connection> = None;
                while let Some(job) = rx.blocking_recv() {
                    if conn.is_none() && path.exists() {
                        match urdr::open_readonly(&path) {
                            Ok(c) => conn = Some(c),
                            Err(e) => {
                                tracing::warn!("cannot open {} read-only: {e}", path.display())
                            }
                        }
                    }
                    job(conn.as_ref());
                }
            })?;
        Ok(WorkDb { tx })
    }

    async fn run<R: Send + 'static>(
        &self,
        f: impl FnOnce(Option<&urdr::Connection>) -> Result<R, String> + Send + 'static,
    ) -> Result<R, String> {
        let (reply, answer) = oneshot::channel();
        let job: Job = Box::new(move |c| {
            let _ = reply.send(f(c));
        });
        self.tx
            .send(job)
            .await
            .map_err(|_| "the work.db thread is gone".to_string())?;
        answer
            .await
            .map_err(|_| "the work.db thread dropped a read".to_string())?
    }

    /// `meta.schema` of work.db; 0 when there is no file (or no `meta` yet).
    pub async fn schema(&self) -> Result<u32, String> {
        self.run(|c| match c {
            None => Ok(0),
            Some(c) => urdr::meta(c, "schema")
                .map(|v| v.and_then(|s| s.trim().parse().ok()).unwrap_or(0))
                .map_err(|e| e.to_string()),
        })
        .await
    }

    /// The newest event's id: where the front's `events` broadcast starts (0 without a file, a table or a row).
    pub async fn last_event_id(&self) -> Result<u64, String> {
        self.run(|c| match c {
            None => Ok(0),
            Some(c) => match c.query_row("select coalesce(max(id), 0) from event", [], |r| {
                r.get::<_, i64>(0)
            }) {
                Ok(n) => Ok(n.max(0) as u64),
                Err(e) if e.to_string().contains("no such table") => Ok(0),
                Err(e) => Err(e.to_string()),
            },
        })
        .await
    }

    /// The events after `since` (0), oldest first, at most `limit` (200; at most 1000; 0 is the default): what
    /// `events/since` answers.  No work.db, or no event table yet, is no events.  `last` is the last id answered, or
    /// `since` when there is none (the Lisp hub's rule: a client's cursor never moves back).
    pub async fn events_since(
        &self,
        since: Option<u64>,
        limit: Option<u64>,
    ) -> Result<EventsPage, String> {
        let since = since.unwrap_or(0);
        let limit = match limit {
            Some(n) if n > 0 => n.min(EVENTS_MAX),
            _ => EVENTS_DEFAULT,
        };
        let events = self
            .run(move |c| match c {
                None => Ok(vec![]),
                Some(c) => event_rows(c, since, limit).map_err(|e| e.to_string()),
            })
            .await?;
        Ok(EventsPage {
            since,
            last: events.last().map_or(since, |e| e.id),
            events,
        })
    }
}

/// The rows of `event` after SINCE.  Each column is cast in SQL, so a value stored with another type (an `at` that
/// is text, an agent that is a number) is read as the column's type instead of failing the page; `data` is the JSON
/// object the column holds, absent when it is none or does not parse as one.
fn event_rows(c: &urdr::Connection, since: u64, limit: u64) -> urdr::Result<Vec<EventRow>> {
    let mut st = match c.prepare(
        "select id, cast(at as real), cast(agent as text), cast(job as text), cast(task as text), \
         cast(kind as text), cast(summary as text), cast(data as text) \
         from event where id > ?1 order by id limit ?2",
    ) {
        Ok(st) => st,
        Err(e) if e.to_string().contains("no such table") => return Ok(vec![]),
        Err(e) => return Err(e.into()),
    };
    let since = i64::try_from(since).unwrap_or(i64::MAX);
    let limit = i64::try_from(limit).unwrap_or(i64::MAX);
    let rows = st.query_map([since, limit], |r| {
        let data: Option<String> = r.get(7)?;
        Ok(EventRow {
            id: r.get::<_, i64>(0)?.max(0) as u64,
            at: r.get(1)?,
            agent: r.get(2)?,
            job: r.get(3)?,
            task: r.get(4)?,
            kind: r.get(5)?,
            summary: r.get(6)?,
            data: data
                .and_then(|d| serde_json::from_str::<Value>(&d).ok())
                .and_then(|v| match v {
                    Value::Object(o) => Some(o),
                    _ => None,
                }),
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn db(dir: &std::path::Path, sql: &str) -> PathBuf {
        let path = dir.join("work.db");
        urdr::Connection::open(&path)
            .unwrap()
            .execute_batch(sql)
            .unwrap();
        path
    }

    #[tokio::test]
    async fn no_file_is_schema_0_and_no_events_then_the_file_is_read_once_it_is_there() {
        let dir = tempfile::tempdir().unwrap();
        let w = WorkDb::spawn(dir.path().join("work.db")).unwrap();
        assert_eq!(w.schema().await.unwrap(), 0);
        let page = w.events_since(None, None).await.unwrap();
        assert_eq!(
            serde_json::to_value(&page).unwrap(),
            json!({"since": 0, "last": 0, "events": []})
        );
        assert_eq!(w.events_since(Some(7), None).await.unwrap().last, 7);
        assert_eq!(w.last_event_id().await.unwrap(), 0);
        assert!(!dir.path().join("work.db").exists(), "a read makes no file");
        db(
            dir.path(),
            "create table meta(key text primary key, value text); insert into meta values ('schema', '6');",
        );
        assert_eq!(w.schema().await.unwrap(), 6);
        // a schema-6 file without an event table yet: no events, not an error
        assert!(w.events_since(None, None).await.unwrap().events.is_empty());
        assert_eq!(w.last_event_id().await.unwrap(), 0);
    }

    #[tokio::test]
    async fn events_are_paged_oldest_first_with_their_data_parsed() {
        let dir = tempfile::tempdir().unwrap();
        let path = db(
            dir.path(),
            "create table event (id integer primary key autoincrement, at real, agent text, job text, task text, \
             kind text, summary text, data text);
             insert into event(at, agent, job, kind, summary, data) values (1.5, 'a', 'j', 'job', 's1', '{\"status\":\"stopped\"}');
             insert into event(at, kind, summary, data) values (2, 'note', 's2', 'not json');
             insert into event(at, agent, kind, data) values ('3', 7, 'note', '[1]');",
        );
        let w = WorkDb::spawn(path).unwrap();
        assert_eq!(w.last_event_id().await.unwrap(), 3);
        let page = serde_json::to_value(w.events_since(Some(0), Some(2)).await.unwrap()).unwrap();
        assert_eq!(
            page,
            json!({"since": 0, "last": 2, "events": [
                {"id": 1, "at": 1.5, "agent": "a", "job": "j", "kind": "job", "summary": "s1", "data": {"status": "stopped"}},
                {"id": 2, "at": 2.0, "kind": "note", "summary": "s2"}]})
        );
        let rest = serde_json::to_value(w.events_since(Some(2), None).await.unwrap()).unwrap();
        assert_eq!(
            rest,
            json!({"since": 2, "last": 3, "events": [{"id": 3, "at": 3.0, "agent": "7", "kind": "note"}]})
        );
        // the answer is what the registry says events/since returns
        let m = runstav::registry::find("events/since").unwrap();
        assert_eq!((m.check_result)(&page).unwrap(), page);
        // a limit of 0 is the default, a huge one the maximum
        assert_eq!(w.events_since(None, Some(0)).await.unwrap().events.len(), 3);
        assert_eq!(
            w.events_since(None, Some(u64::MAX))
                .await
                .unwrap()
                .events
                .len(),
            3
        );
    }
}

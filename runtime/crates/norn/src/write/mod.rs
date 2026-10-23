//! The coordination writers, one file per area (Tasks 4, 5, 6 and 22 write disjoint files).  Since Urdr Task 12 each
//! takes the graph writer's transaction ([`crate::store::WTx`]), so its rows carry the tx and its author.

use crate::store::CoordError;
use std::sync::Arc;
use urdr::graph::excise::{Blanker, Excised};
use urdr::graph::{Tx, WriteError};

pub mod agents;
pub mod cards;
pub mod decisions;
pub mod event;
pub mod jobs;
pub mod messages;
pub mod meta;
pub mod notices;
pub mod prune;
pub mod review;
pub mod spend;
pub mod tasks;

/// A coordination writer's error as the graph writer's.
fn writer_error(e: CoordError) -> WriteError {
    match e {
        CoordError::Refused(t) => WriteError::Refused(t),
        other => WriteError::Sql(other.to_string()),
    }
}

/// The text copies excise must blank in the coordination tables (Task 8's `Blanker`; storage §8.3): the `event`
/// summaries and data, the `message` texts and the `card` titles and data written by an excised tx or about an
/// excised entity.  Add it to every `excise` call.
#[derive(Debug, Default, Clone, Copy)]
pub struct CoordBlanker;

impl Blanker for CoordBlanker {
    fn blank(&self, tx: &mut Tx<'_>, ex: &Excised) -> Result<u64, WriteError> {
        let mut ids: Vec<String> = Vec::new();
        for n in &ex.entities {
            let id: Option<String> = tx
                .sql()
                .query_row("select id from entity where n = ?1", [n], |r| r.get(0))
                .map(Some)
                .or_else(|e| match e {
                    urdr::SqliteError::QueryReturnedNoRows => Ok(None),
                    e => Err(e),
                })?;
            ids.extend(id);
        }
        // `[excised 12]` → `{"excised":12}`, as the entity's own `data` is blanked
        let num: String = ex.marker.chars().filter(char::is_ascii_digit).collect();
        let mark = format!("{{\"excised\":{}}}", if num.is_empty() { "0" } else { &num });
        let mut blanked = 0;
        blanked += event::blank_events(tx, ex, &ids, &mark).map_err(writer_error)?;
        blanked += messages::blank_messages(tx, ex).map_err(writer_error)?;
        blanked += cards::blank_cards(tx, ex, &ids, &mark).map_err(writer_error)?;
        Ok(blanked)
    }
}

/// The blankers every excise carries.
pub fn blankers() -> Vec<Arc<dyn Blanker>> {
    vec![Arc::new(CoordBlanker)]
}

#[cfg(test)]
mod excise_blankers {
    use super::*;
    use crate::store::tests::{db7, tx_of};
    use urdr::graph::entity::{self, EntityNew, Origin};

    fn ex(entities: &[i64], txs: &[i64]) -> Excised {
        Excised {
            entities: entities.to_vec(),
            txs: txs.to_vec(),
            marker: "[excised 77]".into(),
        }
    }

    fn one(tx: &Tx<'_>, sql: &str) -> String {
        tx.sql().query_row(sql, [], |r| r.get(0)).unwrap()
    }

    /// A task entity, as the tracker makes them.
    fn task(tx: &mut Tx<'_>, id: &str) -> i64 {
        entity::create(
            tx,
            EntityNew {
                id: id.into(),
                kind: "task".into(),
                project: None,
                title: Some("t".into()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: serde_json::json!({}),
                origin: Origin::Recorded,
                source: None,
            },
        )
        .unwrap()
        .n
    }

    #[test]
    fn event_payload_blanked() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let n = task(&mut tx, "task:j#1");
        tx.sql()
            .execute_batch(
                "insert into event (at, kind, summary, data, tx) values (1, 'edit', 'secret one', '{\"k\":\"secret\"}', 5);
                 insert into event (at, kind, summary, data, task) values (2, 'status', 'secret two', '{\"s\":1}', 'j#1');
                 insert into event (at, kind, summary, data, task, tx) values (3, 'edit', 'fine', '{\"k\":1}', 'j#2', 6);",
            )
            .unwrap();
        let blanked = CoordBlanker.blank(&mut tx, &ex(&[n], &[5])).unwrap();
        assert_eq!(blanked, 2);
        let rows: Vec<(String, Option<String>)> = {
            let mut st = tx
                .sql()
                .prepare("select summary, data from event order by id")
                .unwrap();
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(
            rows,
            [
                ("[excised 77]".to_string(), Some("{\"excised\":77}".to_string())),
                ("[excised 77]".to_string(), Some("{\"excised\":77}".to_string())),
                ("fine".to_string(), Some("{\"k\":1}".to_string())),
            ]
        );
        // a second pass changes nothing
        assert_eq!(CoordBlanker.blank(&mut tx, &ex(&[n], &[5])).unwrap(), 0);
    }

    #[test]
    fn message_text_blanked() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        tx.sql()
            .execute_batch(
                "insert into message (sender, recipient, text, state, at, tx) values ('a', 'b', 'secret', 'queued', 1, 5);
                 insert into message (sender, recipient, text, state, at, tx) values ('a', 'b', 'fine', 'queued', 2, 6);",
            )
            .unwrap();
        assert_eq!(CoordBlanker.blank(&mut tx, &ex(&[], &[5])).unwrap(), 1);
        let texts: Vec<String> = {
            let mut st = tx
                .sql()
                .prepare("select text from message order by id")
                .unwrap();
            st.query_map([], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(texts, ["[excised 77]", "fine"]);
    }

    #[test]
    fn a_coalesced_notice_is_blanked_by_entity() {
        // the notice was last updated by a tx the excise did not name: its `entity` finds it
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        tx.sql()
            .execute_batch(
                "insert into message (sender, recipient, text, state, at, tx, entity) values (null, 'a', 'task X changed: secret', 'queued', 1, 9, 42);
                 insert into message (sender, recipient, text, state, at, tx, entity) values (null, 'a', 'task Y changed', 'queued', 2, 9, 43);",
            )
            .unwrap();
        assert_eq!(CoordBlanker.blank(&mut tx, &ex(&[42], &[5])).unwrap(), 1);
        let kept = one(&tx, "select text from message where entity = 43");
        assert_eq!(kept, "task Y changed");
        let gone = one(&tx, "select text from message where entity = 42");
        assert_eq!(gone, "[excised 77]");
    }

    #[test]
    fn card_blanked_by_tx_and_task() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        let n = task(&mut tx, "task:t-1");
        tx.sql()
            .execute_batch(
                "insert into card (kind, title, data, state, at, tx) values ('ask', 'secret', '{\"q\":1}', 'open', 1, 5);
                 insert into card (kind, title, data, state, at, tx) values ('close', 'about it', '{\"task\":\"task:t-1\"}', 'open', 2, 8);
                 insert into card (kind, title, data, state, at, tx) values ('ask', 'fine', '{\"task\":\"task:other\"}', 'open', 3, 8);",
            )
            .unwrap();
        assert_eq!(CoordBlanker.blank(&mut tx, &ex(&[n], &[5])).unwrap(), 2);
        let rows: Vec<(String, String)> = {
            let mut st = tx
                .sql()
                .prepare("select title, data from card order by id")
                .unwrap();
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(
            rows,
            [
                ("[excised 77]".to_string(), "{\"excised\":77}".to_string()),
                ("[excised 77]".to_string(), "{\"excised\":77}".to_string()),
                ("fine".to_string(), "{\"task\":\"task:other\"}".to_string()),
            ]
        );
    }
}

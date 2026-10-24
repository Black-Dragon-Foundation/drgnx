//! The cards readers (Task 5): `drgnx-coord-cards` and `drgnx-coord-card`.

use crate::store::{CoordError, Tx};
use serde::Serialize;
use serde_json::Value;

const COLS: &str = "id, job, task, kind, title, data, state, at, settled_at, choice, ref";

/// One card row, typed.  `data` is the stored JSON; `reference` is an `ask` card's question event.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Card {
    pub id: i64,
    pub job: Option<String>,
    pub task: Option<String>,
    pub kind: Option<String>,
    pub title: Option<String>,
    pub data: Option<Value>,
    pub state: Option<String>,
    pub at: Option<f64>,
    pub settled_at: Option<f64>,
    pub choice: Option<String>,
    pub reference: Option<i64>,
}

/// The row mapper (a macro: `norn` does not name rusqlite's `Row` type).
macro_rules! row {
    () => {
        |r| {
            let data: Option<String> = r.get(5)?;
            Ok(Card {
                id: r.get(0)?,
                job: r.get(1)?,
                task: r.get(2)?,
                kind: r.get(3)?,
                title: r.get(4)?,
                data: data.and_then(|d| serde_json::from_str(&d).ok()),
                state: r.get(6)?,
                at: r.get(7)?,
                settled_at: r.get(8)?,
                choice: r.get(9)?,
                reference: r.get(10)?,
            })
        }
    };
}

/// `job`'s cards (only those in `state` when given), newest first.
pub fn cards(conn: &Tx, job: &str, state: Option<&str>) -> Result<Vec<Card>, CoordError> {
    let mut st = conn.prepare(&format!(
        "select {COLS} from card where job = ?1 order by id desc"
    ))?;
    let rows = st.query_map([job], row!())?;
    let mut out = Vec::new();
    for c in rows {
        let c: Card = c?;
        if state.is_none() || c.state.as_deref() == state {
            out.push(c);
        }
    }
    Ok(out)
}

/// Card `id`, or `None`.
pub fn card(conn: &Tx, id: i64) -> Result<Option<Card>, CoordError> {
    match conn.query_row(
        &format!("select {COLS} from card where id = ?1"),
        [id],
        row!(),
    ) {
        Ok(c) => Ok(Some(c)),
        Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    #[test]
    fn cards_come_newest_first_filtered_by_state_with_their_data() {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        c.execute_batch(
            "insert into card (id, job, kind, title, data, state, at) values
               (1, 'j', 'ask', 'a', '{\"gate\":true}', 'open', 1), (2, 'j', 'rate', 'b', null, 'settled', 2),
               (3, 'k', 'ask', 'c', null, 'open', 3);",
        )
        .unwrap();
        let all = cards(&c, "j", None).unwrap();
        assert_eq!(all.iter().map(|c| c.id).collect::<Vec<_>>(), [2, 1]);
        let open = cards(&c, "j", Some("open")).unwrap();
        assert_eq!(open.len(), 1);
        assert_eq!(open[0].data, Some(serde_json::json!({"gate": true})));
        assert!(card(&c, 9).unwrap().is_none());
    }
}

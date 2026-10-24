//! The messages readers (Task 5): `drgnx-coord-inbox`, `-message`, `-queued` and `-message-answers`.

use crate::store::{CoordError, Tx};
use serde::Serialize;

const COLS: &str =
    "id, job, sender, recipient, text, state, reason, at, delivered, read, acted, answers";

/// One message row, typed.  `from_user` is true for a message from the user's own Emacs (sender NULL or `user`);
/// `answers` is the question it answers (M12f-C7-2).
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Message {
    pub id: i64,
    pub job: Option<String>,
    pub sender: Option<String>,
    pub recipient: Option<String>,
    pub text: Option<String>,
    pub state: String,
    pub reason: Option<String>,
    pub at: Option<f64>,
    pub delivered: Option<f64>,
    pub read: Option<f64>,
    pub acted: Option<f64>,
    pub answers: Option<i64>,
    pub from_user: bool,
}

/// The row mapper (a macro: `norn` does not name rusqlite's `Row` type).
macro_rules! row {
    () => {
        |r| {
            let sender: Option<String> = r.get(2)?;
            Ok(Message {
                id: r.get(0)?,
                job: r.get(1)?,
                from_user: matches!(sender.as_deref(), None | Some("user")),
                sender,
                recipient: r.get(3)?,
                text: r.get(4)?,
                state: r.get::<_, Option<String>>(5)?.unwrap_or_default(),
                reason: r.get(6)?,
                at: r.get(7)?,
                delivered: r.get(8)?,
                read: r.get(9)?,
                acted: r.get(10)?,
                answers: r.get(11)?,
            })
        }
    };
}

/// `recipient`'s messages (only those in `states` when any are given), oldest first.
pub fn inbox(conn: &Tx, recipient: &str, states: &[&str]) -> Result<Vec<Message>, CoordError> {
    let mut st = conn.prepare(&format!(
        "select {COLS} from message where recipient = ?1 order by id"
    ))?;
    let rows = st.query_map([recipient], row!())?;
    let mut out = Vec::new();
    for m in rows {
        let m: Message = m?;
        if states.is_empty() || states.contains(&m.state.as_str()) {
            out.push(m);
        }
    }
    Ok(out)
}

/// Message `id`, or `None`.
pub fn message(conn: &Tx, id: i64) -> Result<Option<Message>, CoordError> {
    match conn.query_row(
        &format!("select {COLS} from message where id = ?1"),
        [id],
        row!(),
    ) {
        Ok(m) => Ok(Some(m)),
        Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Every message waiting to be delivered, oldest first.
pub fn queued(conn: &Tx) -> Result<Vec<Message>, CoordError> {
    let mut st = conn.prepare(&format!(
        "select {COLS} from message where state = 'queued' order by id"
    ))?;
    let rows = st.query_map([], row!())?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// Every message being given to a session (`sending`), oldest first: what a crash left half-done.
pub fn sending(conn: &Tx) -> Result<Vec<Message>, CoordError> {
    let mut st = conn.prepare(&format!(
        "select {COLS} from message where state = 'sending' order by id"
    ))?;
    let rows = st.query_map([], row!())?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// The question the user's message `id` answers (`drgnx-coord-message-answers`): the message from `id`'s recipient
/// to `user`.  `None` for another agent's message, for a question of someone else's, or when none was named.
pub fn message_answers(conn: &Tx, id: i64) -> Result<Option<Message>, CoordError> {
    let Some(m) = message(conn, id)? else {
        return Ok(None);
    };
    let Some(q) = m.answers else {
        return Ok(None);
    };
    if !m.from_user {
        return Ok(None);
    }
    Ok(message(conn, q)?
        .filter(|q| q.sender == m.recipient && q.recipient.as_deref() == Some("user")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    fn db() -> urdr::Connection {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        c.execute_batch(
            "insert into message (id, sender, recipient, text, state, at) values
               (1, 'a', 'user', 'q?', 'queued', 1), (2, null, 'a', 'yes', 'queued', 2),
               (3, 'b', 'a', 'hi', 'delivered', 3);
             update message set answers = 1 where id = 2;",
        )
        .unwrap();
        c
    }

    #[test]
    fn inbox_filters_by_state_and_rows_say_who_and_what_they_answer() {
        let c = db();
        let all = inbox(&c, "a", &[]).unwrap();
        assert_eq!(all.iter().map(|m| m.id).collect::<Vec<_>>(), [2, 3]);
        assert!(all[0].from_user && all[0].answers == Some(1) && !all[1].from_user);
        let q = inbox(&c, "a", &["delivered"]).unwrap();
        assert_eq!(q.len(), 1);
        assert_eq!(queued(&c).unwrap().len(), 2);
        assert!(message(&c, 9).unwrap().is_none());
    }

    #[test]
    fn answers_name_the_question_only_when_it_is_the_recipients_to_the_user() {
        let c = db();
        assert_eq!(message_answers(&c, 2).unwrap().unwrap().id, 1);
        assert!(message_answers(&c, 3).unwrap().is_none());
        c.execute("update message set sender = 'z' where id = 1", [])
            .unwrap();
        assert!(message_answers(&c, 2).unwrap().is_none());
    }
}

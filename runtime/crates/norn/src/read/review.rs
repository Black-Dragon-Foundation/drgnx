//! The review-mark reader (Task 5): `drgnx-coord-review-marks`.

use crate::store::{CoordError, Tx};
use serde::Serialize;

/// One of the user's review marks on an agent's change.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReviewMark {
    pub path: String,
    pub state: String,
    pub hash: Option<String>,
    pub at: Option<f64>,
}

/// `agent`'s review marks, by path.
pub fn review_marks(conn: &Tx, agent: &str) -> Result<Vec<ReviewMark>, CoordError> {
    let mut st = conn
        .prepare("select path, state, hash, at from review_mark where agent = ?1 order by path")?;
    let rows = st.query_map([agent], |r| {
        Ok(ReviewMark {
            path: r.get(0)?,
            state: r.get(1)?,
            hash: r.get(2)?,
            at: r.get(3)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

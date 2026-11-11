//! The evidence readers (orchestration in the hub): a task's evidence, oldest first.

use crate::store::{CoordError, Tx};
use vordr::evidence::Evidence;

/// TASK's live evidence records, in the order they were written.
pub fn of_task(conn: &Tx, task: &str) -> Result<Vec<Evidence>, CoordError> {
    let mut st = conn.prepare(
        "select data from entity where kind = 'evidence' and retired_tx is null \
         and json_extract(data, '$.task') = ?1 order by n",
    )?;
    let rows = st.query_map([task], |r| r.get::<_, String>(0))?;
    let mut out = Vec::new();
    for row in rows {
        if let Ok(e) = serde_json::from_str::<Evidence>(&row?) {
            out.push(e);
        }
    }
    Ok(out)
}

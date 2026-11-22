//! The evidence readers (orchestration in the hub): a task's evidence, oldest first.

use crate::store::{CoordError, Tx};
use vordr::evidence::Evidence;
use vordr::pack::Pack;

/// The rule pack job JOB was approved with (the latest record), if any.
pub fn pack_of_job(conn: &Tx, job: &str) -> Result<Option<Pack>, CoordError> {
    let mut st = conn.prepare(
        "select json_extract(data, '$.pack') from entity where kind = 'rule_pack' and retired_tx is null \
         and json_extract(data, '$.job') = ?1 order by n desc limit 1",
    )?;
    let mut rows = st.query_map([job], |r| r.get::<_, String>(0))?;
    Ok(match rows.next() {
        Some(row) => serde_json::from_str(&row?).ok(),
        None => None,
    })
}

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

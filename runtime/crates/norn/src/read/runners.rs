//! The runner readers (runners plan, Task 19): the live records of one kind, as the hub wrote them.

use crate::store::{CoordError, Tx};
use serde_json::Value;

/// The live records of KIND (`runner`, ...) as `(name, data)`, by name.
pub fn list(conn: &Tx, kind: &str) -> Result<Vec<(String, Value)>, CoordError> {
    let mut st = conn.prepare(
        "select title, data from entity where kind = ?1 and retired_tx is null order by title",
    )?;
    let rows = st.query_map([kind], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (name, data) = row?;
        out.push((name, serde_json::from_str(&data).unwrap_or(Value::Null)));
    }
    Ok(out)
}

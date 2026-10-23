//! The meta helpers (Task 4): `log-version`, `seen:AGENT` and `held:AGENT` (`core/drgnx-coord.el`).  Every value is
//! decimal text, as the Lisp writes it.

use crate::store::{CoordError, Tx};

fn get(conn: &Tx, key: &str) -> Result<u64, CoordError> {
    let v: Option<String> =
        match conn.query_row("select value from meta where key = ?1", [key], |r| r.get(0)) {
            Ok(v) => Some(v),
            Err(urdr::SqliteError::QueryReturnedNoRows) => None,
            Err(e) => return Err(e.into()),
        };
    // `string-to-number`: text that is not a number reads as 0.
    Ok(v.and_then(|s| s.trim().parse().ok()).unwrap_or(0))
}

fn put(tx: &Tx, key: &str, value: u64) -> Result<(), CoordError> {
    tx.execute(
        "insert or replace into meta values (?1, ?2)",
        (key, value.to_string()),
    )?;
    Ok(())
}

/// The decision log's version (`drgnx-coord-version`); 0 when never bumped.
pub fn version(conn: &Tx) -> Result<u64, CoordError> {
    get(conn, "log-version")
}

/// One more than the log's version, stored and returned (`drgnx-coord--bump`).
pub fn bump_version(tx: &Tx) -> Result<u64, CoordError> {
    let v = version(tx)? + 1;
    put(tx, "log-version", v)?;
    Ok(v)
}

/// AGENT has read the decision log up to `v` (`drgnx-coord-set-seen`).
pub fn set_seen(tx: &Tx, agent: &str, v: u64) -> Result<(), CoordError> {
    put(tx, &format!("seen:{agent}"), v)
}

/// The version AGENT last read (`drgnx-coord-seen`); 0 when never.
pub fn seen(conn: &Tx, agent: &str) -> Result<u64, CoordError> {
    get(conn, &format!("seen:{agent}"))
}

/// AGENT's coordination write was held (`Some(version)`, the count goes up by one) or went through (`None`, the
/// count is 0) (`drgnx-coord-note-held`).  The stored value is the count of held writes in a row; `Some`'s argument
/// is not stored (the Lisp ignores its argument beyond truthiness).
pub fn note_held(tx: &Tx, agent: &str, held: Option<u64>) -> Result<(), CoordError> {
    let key = format!("held:{agent}");
    let n = if held.is_some() {
        get(tx, &key)? + 1
    } else {
        0
    };
    put(tx, &key, n)
}

/// AGENT's held writes in a row (`drgnx-coord-held`).
pub fn held(conn: &Tx, agent: &str) -> Result<u64, CoordError> {
    get(conn, &format!("held:{agent}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::DDL;

    #[test]
    fn version_seen_and_held() {
        let c = urdr::Connection::open_in_memory().unwrap();
        c.execute_batch(DDL).unwrap();
        assert_eq!(version(&c).unwrap(), 0);
        assert_eq!(bump_version(&c).unwrap(), 1);
        assert_eq!(bump_version(&c).unwrap(), 2);
        set_seen(&c, "a", 2).unwrap();
        assert_eq!(seen(&c, "a").unwrap(), 2);
        assert_eq!(seen(&c, "b").unwrap(), 0);
        note_held(&c, "a", Some(2)).unwrap();
        note_held(&c, "a", Some(2)).unwrap();
        assert_eq!(held(&c, "a").unwrap(), 2);
        note_held(&c, "a", None).unwrap();
        assert_eq!(held(&c, "a").unwrap(), 0);
    }
}

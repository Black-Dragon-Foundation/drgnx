//! The meta helpers (Task 4, moved to `kv` by Urdr Task 12): `log-version`, `seen:AGENT` and `held:AGENT`
//! (`core/drgnx-coord.el`).  Every value is decimal text, as the Lisp writes it.  The hub's keys live in the `kv`
//! table; `meta` is the read-only view the Lisp readers see.  A write goes through the class guard (`setting:` keys
//! are the user's).

use crate::store::{CoordError, Tx, WTx};
use urdr::graph::guard;

fn get(conn: &Tx, key: &str) -> Result<u64, CoordError> {
    let v: Option<String> =
        match conn.query_row("select value from kv where key = ?1", [key], |r| r.get(0)) {
            Ok(v) => Some(v),
            Err(urdr::SqliteError::QueryReturnedNoRows) => None,
            Err(e) => return Err(e.into()),
        };
    // `string-to-number`: text that is not a number reads as 0.
    Ok(v.and_then(|s| s.trim().parse().ok()).unwrap_or(0))
}

/// `kv[key] = value`, after the guard has looked at the key.
pub(crate) fn put_text(tx: &mut WTx<'_>, key: &str, value: &str) -> Result<(), CoordError> {
    guard::check_key(tx.guard(), tx.meta(), key)?;
    tx.sql().execute(
        "insert or replace into kv (key, value) values (?1, ?2)",
        (key, value),
    )?;
    Ok(())
}

/// The text of `kv[key]`, or `None`.
pub(crate) fn get_text(conn: &Tx, key: &str) -> Result<Option<String>, CoordError> {
    match conn.query_row("select value from kv where key = ?1", [key], |r| r.get(0)) {
        Ok(v) => Ok(Some(v)),
        Err(urdr::SqliteError::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

fn put(tx: &mut WTx<'_>, key: &str, value: u64) -> Result<(), CoordError> {
    put_text(tx, key, &value.to_string())
}

/// The decision log's version (`drgnx-coord-version`); 0 when never bumped.
pub fn version(conn: &Tx) -> Result<u64, CoordError> {
    get(conn, "log-version")
}

/// One more than the log's version, stored and returned (`drgnx-coord--bump`).
pub fn bump_version(tx: &mut WTx<'_>) -> Result<u64, CoordError> {
    let v = version(tx.sql())? + 1;
    put(tx, "log-version", v)?;
    Ok(v)
}

/// AGENT has read the decision log up to `v` (`drgnx-coord-set-seen`).
pub fn set_seen(tx: &mut WTx<'_>, agent: &str, v: u64) -> Result<(), CoordError> {
    put(tx, &format!("seen:{agent}"), v)
}

/// The version AGENT last read (`drgnx-coord-seen`); 0 when never.
pub fn seen(conn: &Tx, agent: &str) -> Result<u64, CoordError> {
    get(conn, &format!("seen:{agent}"))
}

/// AGENT's coordination write was held (`Some(version)`, the count goes up by one) or went through (`None`, the
/// count is 0) (`drgnx-coord-note-held`).  The stored value is the count of held writes in a row; `Some`'s argument
/// is not stored (the Lisp ignores its argument beyond truthiness).
pub fn note_held(tx: &mut WTx<'_>, agent: &str, held: Option<u64>) -> Result<(), CoordError> {
    let key = format!("held:{agent}");
    let n = if held.is_some() {
        get(tx.sql(), &key)? + 1
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
    use crate::store::tests::{db7, tx_of};

    #[test]
    fn version_seen_and_held() {
        let mut c = db7();
        let mut tx = tx_of(&mut c);
        assert_eq!(version(tx.sql()).unwrap(), 0);
        assert_eq!(bump_version(&mut tx).unwrap(), 1);
        assert_eq!(bump_version(&mut tx).unwrap(), 2);
        set_seen(&mut tx, "a", 2).unwrap();
        assert_eq!(seen(tx.sql(), "a").unwrap(), 2);
        assert_eq!(seen(tx.sql(), "b").unwrap(), 0);
        note_held(&mut tx, "a", Some(2)).unwrap();
        note_held(&mut tx, "a", Some(2)).unwrap();
        assert_eq!(held(tx.sql(), "a").unwrap(), 2);
        note_held(&mut tx, "a", None).unwrap();
        assert_eq!(held(tx.sql(), "a").unwrap(), 0);
    }

    #[test]
    fn the_key_guard_is_asked() {
        // an agent may not write a `setting:` key (Task 10's rule), the hub's own keys pass
        let mut c = db7();
        let mut guard = urdr::graph::guard::Guard::default();
        crate::grants::register(&mut guard);
        let meta = urdr::graph::TxMeta::new("agent:s", urdr::graph::Class::Agent, "mcp:x");
        let mut tx = urdr::graph::Tx::for_test(&mut c, meta, std::sync::Arc::new(guard));
        assert!(put_text(&mut tx, "setting:only-user-closes", "1").is_err());
        put_text(&mut tx, "log-version", "3").unwrap();
    }
}

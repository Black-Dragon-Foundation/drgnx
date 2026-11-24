//! norn: `work.db`'s coordination writer (docs/develop/coordination.md, "The writer"), and drgnx's policy over the
//! graph store (docs/develop/store.md).
//!
//! - [`store`]: one read-write connection on its own thread, opened only on a schema-6 file the Lisp side made.
//! - [`write`]: the coordination writers (ported from the old Lisp store, whose cases are kept as fixtures).
//! - [`read`]: the readers the writers and the tools need.
//! - [`tools`]: the coordination tools, served by `mimir`.
//! - Schema 7 (the Urdr plan): [`kinds`], [`deny`], [`scope`], [`grants`], [`trust`], [`project`] (the policy),
//!   [`migrate7`] (6 → 7), [`parsed`] (the scan's door), [`privacy`] (the opt-in), [`tracker`] (tasks agents share),
//!   [`options`] (settings history: kind `option`, its ids, the settings deny-list, the `options` grant's rule).
//! - [`hooks`]: the hook engine, which combines rules' and plugins' verdicts under the matrix (narrowing only).

pub mod bindings;
pub mod deny;
pub mod forecast;
pub mod grants;
pub mod hooks;
pub mod kinds;
pub mod matrix;
pub mod migrate10;
pub mod migrate11;
pub mod migrate12;
pub mod migrate13;
pub mod migrate14;
pub mod migrate15;
pub mod migrate16;
pub mod migrate7;
pub mod migrate8;
pub mod migrate9;
pub mod options;
pub mod parsed;
pub mod privacy;
pub mod project;
pub mod read;
pub mod scope;
pub mod store;
pub mod tools;
pub mod tracker;
pub mod trust;
pub mod write;

/// Undo the open transaction on CONN after a failure that is already being returned: a rollback that fails too is
/// logged, and the first error stays the one the caller sees.
pub(crate) fn rollback(conn: &urdr::Connection) {
    if let Err(e) = conn.execute_batch("rollback") {
        tracing::warn!(error = %e, "a rollback failed");
    }
}

/// R, the result of removing a file nobody can act on the loss of: a file that is already gone is the wanted end; any
/// other failure is logged under WHAT.
pub(crate) fn removed(r: std::io::Result<()>, what: &str) {
    if let Err(e) = r
        && e.kind() != std::io::ErrorKind::NotFound
    {
        tracing::warn!(error = %e, what, "a removal failed");
    }
}

//! norn: `work.db`'s coordination writer (docs/develop/coordination.md, "The writer"), and drgnx's policy over the
//! graph store (docs/develop/store.md).
//!
//! - [`store`]: one read-write connection on its own thread, opened only on a schema-6 file the Lisp side made.
//! - [`write`]: the writers of `core/drgnx-coord.el`, ported with the Lisp as the oracle.
//! - [`read`]: the readers the writers and the tools need.
//! - [`tools`]: the coordination tools, served by `mimir`.
//! - Schema 7 (the Urdr plan): [`kinds`], [`deny`], [`scope`], [`grants`], [`trust`], [`project`] (the policy),
//!   [`migrate7`] (6 → 7), [`parsed`] (the scan's door), [`privacy`] (the opt-in), [`tracker`] (tasks agents share),
//!   [`options`] (settings history: kind `option`, its ids, the settings deny-list, the `options` grant's rule).

pub mod deny;
pub mod grants;
pub mod kinds;
pub mod migrate7;
pub mod migrate8;
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

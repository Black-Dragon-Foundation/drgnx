//! norn: `work.db`'s coordination writer (docs/develop/coordination.md, "The writer").
//!
//! - [`store`]: one read-write connection on its own thread, opened only on a schema-6 file the Lisp side made.
//! - [`write`]: the writers of `core/drgnx-coord.el`, ported with the Lisp as the oracle.
//! - [`read`]: the readers the writers and the tools need.
//! - [`tools`]: the 16 coordination tools, served by `mimir`.

pub mod read;
pub mod store;
pub mod tools;
pub mod write;

//! The Extensions view's catalog in the hub (`extensions/*`; docs/develop/hub.md, "Extensions").
//!
//! - [`catalog`]: the sources in memory, the cache that reads one again when its `(mtime, size)` changes, and the merge
//!   into rows.
//! - [`rank`]: which rows a query keeps and in what order.
//! - [`plugins`]: the installed plugins as rows, with On and Off from the user's plugins setting.
//! - [`methods`]: the four methods and the files they read.
//!
//! The hub never installs and never reaches the network here: the refresh job (`drgnx extensions refresh`) writes
//! `<cache>/extensions/catalog.json`, `drgnx sync` writes the lock, and the hub reads both.

pub mod catalog;
pub mod methods;
pub mod plugins;
pub mod rank;

pub use methods::Hub;

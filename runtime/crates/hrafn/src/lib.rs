//! hrafn: code search for drgnx.
//!
//! The crate is generic: it has no hub types, and the binary passes in its paths. `store` is the code store
//! (`<state>/code/<project-id>.db`), `schema` its migrations and the symbol encoding.

pub mod coverage;
pub mod files;
pub mod schema;
pub mod store;

pub use coverage::{CoverageError, coverage};
#[cfg(feature = "host")]
pub use files::GitCli;
pub use files::{Class, Config, Git, Lang, Listed, list};

pub use schema::{MIGRATIONS, encode_symbol};
pub use store::{ChunkIn, CodeStore, FileRow, StoreError, SymbolIn, VecRow, vec_key};

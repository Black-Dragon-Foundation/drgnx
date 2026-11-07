//! hrafn: code search for drgnx.
//!
//! The crate is generic: it has no hub types, and the binary passes in its paths. `store` is the code store
//! (`<state>/code/<project-id>.db`), `schema` its migrations and the symbol encoding. `index` is tier 1 and the store
//! side of tier 2, `fresh` when tier 1 runs, and `watch` the file watcher behind a trait.

pub mod chunk;
pub mod coverage;
pub mod eval;
pub mod files;
pub mod fresh;
pub mod index;
pub mod query;
pub mod schema;
pub mod store;
pub mod watch;

pub use coverage::{CoverageError, coverage};
pub use files::{Change, Class, Commit, Config, Git, Lang, Listed, classify, list};
#[cfg(feature = "host")]
pub use files::{GitCli, ignored_dirs, is_ignored_dir};
pub use index::{Lag, Refresh, collect, lag, missing, put_vectors, refresh, reset};
pub use query::{Answer, Hit, Query, Scope, search};
#[cfg(feature = "host")]
pub use watch::{AddError, Adder, NotifyWatch, Walker, WatchState};
pub use watch::{Watch, WatchEvent};

pub use schema::{MIGRATIONS, encode_symbol};
pub use store::{ChunkIn, CodeStore, FileRow, StoreError, SymbolIn, VecRow, vec_key};

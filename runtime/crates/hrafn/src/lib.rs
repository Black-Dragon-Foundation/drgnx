//! hrafn: code search for drgnx.
//!
//! The crate is generic: it has no hub types, and the binary passes in its paths. `store` is the code store
//! (`<state>/code/<project-id>.db`), `schema` its migrations and the symbol encoding. `index` is tier 1 and the store
//! side of tier 2, `fresh` when tier 1 runs, and `watch` the file watcher behind a trait.

pub mod chunk;
pub mod coverage;
pub mod door;
pub mod eval;
pub mod files;
pub mod fresh;
pub mod graph;
pub mod grep;
pub mod index;
pub mod map;
mod memo;
pub mod overlay;
pub mod query;
pub mod rank;
pub mod refs;
pub mod schema;
pub mod store;
pub mod structural;
pub mod symbols;
pub mod tree;
pub mod watch;

pub use coverage::{CoverageError, coverage};
pub use door::{Blob, DoorKind, Head, Obj, Status, TreeChange, TreeEntry, TreeGit};
#[cfg(feature = "host")]
pub use door::{GixDoor, door};
pub use files::{Change, Class, Commit, Config, Git, Lang, Listed, classify, list};
#[cfg(feature = "host")]
pub use files::{GitCli, ignored_dirs, is_ignored_dir};
pub use index::{Lag, Refresh, collect, lag, missing, put_vectors, refresh, reset};
pub use query::{Answer, Hit, Query, Scope, search};
pub use watch::{
    AddError, MAIN_TREE, ProjectWatch, Router, TreeSpec, Watch, WatchEvent, WatchState,
};
#[cfg(feature = "host")]
pub use watch::{Adder, HostWatch, Walker};

pub use schema::{MIGRATIONS, encode_symbol};
pub use store::{ChunkIn, CodeStore, FileRow, RefIn, StoreError, SymbolIn, VecRow, vec_key};
pub use tree::{TreeId, TreeRow, TreeState, View};

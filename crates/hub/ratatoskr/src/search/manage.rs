//! Managing indexing (Hrafn redesign §11A): every root's index has a state the user controls, kept in its store's
//! metadata (`index_state`), so a hub restart or a file change does not undo it.
//!
//! - **pause** (`search/pause`): the batch in flight finishes, then tier 2 does nothing until **resume**; queries still
//!   answer from what is indexed. **resume** continues with the keys still missing: nothing done is redone.
//! - **stop** (`search/stop`): the running build is cancelled now and the finished part kept; the watcher stays on, and
//!   the next change or `search/index` continues from there.
//! - **delete** (`search/delete`): the root's store and packs go, and its vectors with them, except those another
//!   root's store still holds; the deletion is recorded with its reason. It asks first (`--yes` skips the question) and
//!   is the user's only: no MCP tool reaches it.
//! - **Automatic pauses** (battery, no embedder; load and the disk floor have no gate in tier 2 yet) hold and clear by
//!   themselves, and never clear the user's pause: [`RootState`] says which reason holds, the user's first.
//! - **list** and **status** are what an agent may see too.

use super::caches::Caches;
use std::path::{Path, PathBuf};

/// The store metadata key of the user's state.
pub const META_STATE: &str = "index_state";

/// Why a root's index waits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PauseWhy {
    /// `search pause`.
    User,
    /// On battery, with only local sources to fill.
    Battery,
    /// The machine is busy.
    Load,
    /// The disk is near its floor.
    DiskFloor,
    /// No source answers.
    NoEmbedder,
}

impl PauseWhy {
    pub fn name(self) -> &'static str {
        match self {
            PauseWhy::User => "user",
            PauseWhy::Battery => "battery",
            PauseWhy::Load => "load",
            PauseWhy::DiskFloor => "disk-floor",
            PauseWhy::NoEmbedder => "no-embedder",
        }
    }

    /// What `status` says of it.
    pub fn text(self) -> &'static str {
        unimplemented!("Wave 9 stub")
    }
}

/// A root's index as the user sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RootState {
    /// Nothing to do.
    Idle,
    /// Filling vectors.
    Running,
    /// Waiting, and why.
    Paused(PauseWhy),
    /// Stopped by the user: the next change or `index` continues.
    Stopped,
}

impl RootState {
    pub fn name(self) -> &'static str {
        match self {
            RootState::Idle => "idle",
            RootState::Running => "running",
            RootState::Paused(_) => "paused",
            RootState::Stopped => "stopped",
        }
    }

    pub fn why(self) -> Option<PauseWhy> {
        match self {
            RootState::Paused(w) => Some(w),
            _ => None,
        }
    }
}

/// What the user set, as the store's metadata holds it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UserState {
    On,
    Paused,
    Stopped,
}

impl UserState {
    pub fn as_str(self) -> &'static str {
        match self {
            UserState::On => "on",
            UserState::Paused => "paused",
            UserState::Stopped => "stopped",
        }
    }

    pub fn parse(s: Option<&str>) -> UserState {
        match s {
            Some("paused") => UserState::Paused,
            Some("stopped") => UserState::Stopped,
            _ => UserState::On,
        }
    }
}

/// What a delete freed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Deleted {
    /// Bytes of the store and the packs.
    pub bytes: u64,
    /// Vectors no other root held.
    pub vectors: u64,
    /// Packs removed from the root's `.drgnx/packs/`.
    pub packs: u64,
}

/// Deletes the index of the store ID (`<state>/code/<ID>.db`, its base checkout BASE): its holds in every cache of
/// CACHES (with the vectors only it held), the store's files, and BASE's `.drgnx/packs/`. The project must be closed.
pub async fn delete_root(
    caches: &Caches,
    id: &str,
    base: Option<&Path>,
) -> Result<Deleted, String> {
    let _ = (caches, id, base);
    unimplemented!("Wave 9 stub")
}

/// The files of store ID under STATE: the database and its WAL and shared-memory files.
pub fn store_files(state: &Path, id: &str) -> Vec<PathBuf> {
    let db = super::project::store_path(state, id);
    let mut out = vec![db.clone()];
    for ext in ["db-wal", "db-shm"] {
        out.push(db.with_extension(ext));
    }
    out
}

//! The hub's vector caches (Hrafn redesign §7.1): one [`hrafn::VectorCache`] per fingerprint under
//! `<state>/vectors/`, opened as its writer the first time a fingerprint is used, and shared by every project of the
//! state (one [`Caches`] per state directory in the process, [`Caches::shared`]).
//!
//! - **Holders.** At a cache's first open every repo store on disk (`<state>/code/*.db`) is registered as a holder
//!   (MP-21); each refresh then reports its store's live key set (`hrafn::hold`).
//! - **The sweep.** At most once per [`CACHE_SWEEP`] (beside the projects' tree sweep): holders whose checkout is gone
//!   past `TREE_IDLE` are released, then each cache is collected down to `drgnx-search-cache-cap` bytes of unheld
//!   keys (nil: twice the held bytes, at least 1 GiB).

use hrafn::{StoreError, VectorCache};
use hrafn_embed::fingerprint::Identity;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// How often the caches are swept.
pub const CACHE_SWEEP: Duration = Duration::from_secs(3600);

/// The vector caches of one state directory.
pub struct Caches {
    dir: PathBuf,
}

impl Caches {
    /// The caches of STATE (`STATE/vectors/`): one per state directory in this process, so two projects of the state
    /// share each cache's one writer.
    pub fn shared(state: &Path) -> Arc<Caches> {
        unimplemented!("{}", state.display())
    }

    /// `<state>/vectors/`.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// ID's cache, opened (as its writer, created when there is none) on first use.
    pub async fn get(&self, id: &Identity) -> Result<Arc<VectorCache>, StoreError> {
        unimplemented!("{}", id.fp.hex())
    }

    /// The caches opened so far.
    pub async fn opened(&self) -> Vec<Arc<VectorCache>> {
        unimplemented!()
    }

    /// `drgnx-search-cache-cap`: the bytes of unheld keys a collection keeps (none: MP-7's rule).
    pub fn set_cap(&self, cap: Option<u64>) {
        unimplemented!("{cap:?}")
    }

    /// The sweep, when [`CACHE_SWEEP`] has passed since the last (NOW the virtual clock's, NOW_MS the wall clock's
    /// milliseconds): gone holders released, then each open cache collected. How many vectors went; none when not due.
    pub async fn sweep_if_due(
        &self,
        now: tokio::time::Instant,
        now_ms: i64,
    ) -> Result<Option<u32>, StoreError> {
        unimplemented!("{now:?} {now_ms}")
    }
}

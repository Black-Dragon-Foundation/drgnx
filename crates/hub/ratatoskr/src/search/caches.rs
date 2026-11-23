//! The hub's vector caches (Hrafn redesign §7.1): one [`hrafn::VectorCache`] per fingerprint under
//! `<state>/vectors/`, opened as its writer the first time a fingerprint is used, and shared by every project of the
//! state (one [`Caches`] per state directory in the process, [`Caches::shared`]).
//!
//! - **Holders.** At a cache's first open every repo store on disk (`<state>/code/*.db`) is registered as a holder
//!   (MP-21); each refresh then reports its store's live key set (`hrafn::hold`).
//! - **The sweep.** At most once per [`CACHE_SWEEP`] (beside the projects' tree sweep): holders whose checkout is gone
//!   past `TREE_IDLE` are released, then each cache is collected down to `drgnx-search-cache-cap` bytes of unheld
//!   keys (nil: twice the held bytes, at least 1 GiB).

use super::project::TREE_IDLE;
use hrafn::cache::default_cap;
use hrafn::{StoreError, VectorCache};
use hrafn_embed::fingerprint::Identity;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak};
use std::time::Duration;

/// How often the caches are swept.
pub const CACHE_SWEEP: Duration = Duration::from_secs(3600);

/// The vector caches of one state directory.
pub struct Caches {
    state: PathBuf,
    dir: PathBuf,
    /// The caches opened, by fingerprint hex (a lock held across an open, so a fingerprint is opened once).
    open: tokio::sync::Mutex<HashMap<String, Arc<VectorCache>>>,
    cap: Mutex<Option<u64>>,
    last_sweep: Mutex<Option<tokio::time::Instant>>,
}

/// The process's caches, by state directory.
fn registry() -> &'static Mutex<HashMap<PathBuf, Weak<Caches>>> {
    static R: OnceLock<Mutex<HashMap<PathBuf, Weak<Caches>>>> = OnceLock::new();
    R.get_or_init(Default::default)
}

impl Caches {
    /// The caches of STATE (`STATE/vectors/`): one per state directory in this process, so two projects of the state
    /// share each cache's one writer.
    pub fn shared(state: &Path) -> Arc<Caches> {
        let mut r = registry().lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(c) = r.get(state).and_then(Weak::upgrade) {
            return c;
        }
        r.retain(|_, w| w.strong_count() > 0);
        let c = Arc::new(Caches {
            state: state.to_path_buf(),
            dir: state.join("vectors"),
            open: Default::default(),
            cap: Mutex::new(None),
            last_sweep: Mutex::new(None),
        });
        r.insert(state.to_path_buf(), Arc::downgrade(&c));
        c
    }

    /// `<state>/vectors/`.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// ID's cache, opened (as its writer, created when there is none) on first use; then every repo store of the state
    /// is a holder.
    pub async fn get(&self, id: &Identity) -> Result<Arc<VectorCache>, StoreError> {
        let hex = id.fp.hex();
        let mut open = self.open.lock().await;
        if let Some(c) = open.get(&hex) {
            return Ok(c.clone());
        }
        let c = Arc::new(VectorCache::open_writer(
            &self.dir,
            &hex,
            &id.record.to_json(),
        )?);
        for store in repo_stores(&self.state) {
            c.register(&store).await?;
        }
        open.insert(hex, c.clone());
        Ok(c)
    }

    /// The caches opened so far.
    pub async fn opened(&self) -> Vec<Arc<VectorCache>> {
        self.open.lock().await.values().cloned().collect()
    }

    /// The state directory the caches belong to (`<state>/code/` holds the repo stores).
    pub fn state(&self) -> &Path {
        &self.state
    }

    /// The identity (record and a label) of every cache file on disk, opened or not.
    pub fn stored(&self) -> Vec<Identity> {
        let Ok(rd) = std::fs::read_dir(&self.dir) else {
            return Vec::new();
        };
        let mut out: Vec<Identity> = rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "db"))
            .filter_map(|p| {
                let c = urdr::open_readonly(&p).ok()?;
                let record = hrafn_embed::fingerprint::FingerprintRecord::from_json(
                    &urdr::meta(&c, "record").ok()??,
                )
                .ok()?;
                let id = Identity::new(record.clone(), record.model_id.clone());
                (urdr::meta(&c, "fingerprint").ok()?? == id.fp.hex()).then_some(id)
            })
            .collect();
        out.sort_by_key(|i| i.fp);
        out
    }

    /// `drgnx-search-cache-cap`: the bytes of unheld keys a collection keeps (none: MP-7's rule).
    pub fn set_cap(&self, cap: Option<u64>) {
        *self.cap.lock().unwrap_or_else(PoisonError::into_inner) = cap;
    }

    /// The sweep, when [`CACHE_SWEEP`] has passed since the last (NOW the virtual clock's, NOW_MS the wall clock's
    /// milliseconds): gone holders released, then each open cache collected. How many vectors went; none when not due.
    pub async fn sweep_if_due(
        &self,
        now: tokio::time::Instant,
        now_ms: i64,
    ) -> Result<Option<u32>, StoreError> {
        {
            let mut last = self
                .last_sweep
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if last.is_some_and(|t| now.saturating_duration_since(t) < CACHE_SWEEP) {
                return Ok(None);
            }
            *last = Some(now);
        }
        let cap = *self.cap.lock().unwrap_or_else(PoisonError::into_inner);
        let mut gone = 0u32;
        for c in self.opened().await {
            c.release_gone(now_ms, TREE_IDLE).await?;
            let cap = match cap {
                Some(b) => b,
                None => default_cap(c.live_bytes().await?),
            };
            gone = gone.saturating_add(c.collect(cap).await?);
        }
        Ok(Some(gone))
    }
}

/// The ids (file stems) of STATE's repo stores, `<state>/code/*.db`.
fn repo_stores(state: &Path) -> Vec<String> {
    let Ok(rd) = std::fs::read_dir(state.join("code")) else {
        return Vec::new();
    };
    let mut out: Vec<String> = rd
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "db"))
        .filter_map(|p| p.file_stem().map(|s| s.to_string_lossy().into_owned()))
        .collect();
    out.sort();
    out
}

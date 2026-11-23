//! The machine-wide vector cache (Hrafn redesign §7.1, MP-6/7/21): one SQLite file per fingerprint,
//! `<state>/vectors/<fingerprint-hex16>.db`, written by one process (the hub) and read by every repo store's connection,
//! which attaches it read-only as `vc` (`store::ensure_vc`).
//!
//! - **Tables.** `chunk_vec` and `path_vec` `(key, bits, vec, scale, last_used)`, one per [`KeyKind`]; `meta` holds the
//!   full fingerprint and its record (a file whose `fingerprint` is another is refused, so two fingerprints with the
//!   same first 16 hex characters never share one); `holder` and `held` say which repo stores hold which keys.
//! - **One writer.** [`VectorCache::open_writer`] takes an exclusive lock on `<db>.writer` (it holds the writer's PID);
//!   a second writer is refused with [`StoreError::Busy`]. Readers ([`VectorCache::open`], and the stores' `vc`) never
//!   block: WAL.
//! - **Collection.** A key is kept while a live holder holds it; of the rest, the most recently used are kept up to a
//!   cap in bytes ([`default_cap`]: twice the held keys' bytes, at least [`MIN_CAP`]). `last_used` is a logical clock,
//!   moved by a write and by a holder's taking or dropping the key.

use crate::store::{KeyKind, StoreError};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// A vector as the cache stores it: `vec` holds the sign bits (`dims / 8` bytes, rounded up) and then the int8 values
/// (`urdr::graph::search::vec::quantize`), `scale` their scale; `bits` is 8.
#[derive(Clone, Debug, PartialEq)]
pub struct QuantRow {
    pub key: [u8; 32],
    pub bits: u8,
    pub vec: Vec<u8>,
    pub scale: f64,
}

/// The least cap [`default_cap`] gives: 1 GiB.
pub const MIN_CAP: u64 = 1 << 30;

/// MP-7's cap on unheld keys' bytes: twice what live holders hold, and at least [`MIN_CAP`].
pub fn default_cap(live_bytes: u64) -> u64 {
    unimplemented!("{live_bytes}")
}

/// One fingerprint's cache file.
pub struct VectorCache {
    path: PathBuf,
    fp_hex: String,
}

impl VectorCache {
    /// `<dir>/<fp_hex[..16]>.db`.
    pub fn file_of(dir: &Path, fp_hex: &str) -> PathBuf {
        dir.join(format!("{}.db", &fp_hex[..fp_hex.len().min(16)]))
    }

    /// A reader of FP_HEX's cache in DIR (the file must exist). A file whose `meta.fingerprint` is not FP_HEX is
    /// refused ([`StoreError::Mismatch`]). RECORD_JSON is the fingerprint's record, kept with a new file.
    pub fn open(dir: &Path, fp_hex: &str, record_json: &str) -> Result<VectorCache, StoreError> {
        unimplemented!("{} {fp_hex} {record_json}", dir.display())
    }

    /// The writer of FP_HEX's cache in DIR, created (0600, WAL) when there is none. Refused while another holds
    /// `<db>.writer` ([`StoreError::Busy`]), and for a file of another fingerprint.
    pub fn open_writer(
        dir: &Path,
        fp_hex: &str,
        record_json: &str,
    ) -> Result<VectorCache, StoreError> {
        unimplemented!("{} {fp_hex} {record_json}", dir.display())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The full fingerprint (64 hex characters) its vectors are of.
    pub fn fp_hex(&self) -> &str {
        &self.fp_hex
    }

    /// Whether each of KEYS has a vector of KIND.
    pub async fn has(&self, kind: KeyKind, keys: &[[u8; 32]]) -> Result<Vec<bool>, StoreError> {
        unimplemented!("{kind:?} {}", keys.len())
    }

    /// ROWS quantized and written (a key's vector replaced). A row of other than DIMS values is an error, and nothing
    /// of the batch is written.
    pub async fn put(
        &self,
        kind: KeyKind,
        dims: u32,
        rows: &[([u8; 32], Vec<f32>)],
    ) -> Result<(), StoreError> {
        unimplemented!("{kind:?} {dims} {}", rows.len())
    }

    /// Rows already in the stored form written as they are (a vector pack's).
    pub async fn put_quantized(&self, kind: KeyKind, rows: &[QuantRow]) -> Result<(), StoreError> {
        unimplemented!("{kind:?} {}", rows.len())
    }

    /// The stored rows of those of KEYS that have a vector of KIND, in KEYS' order.
    pub async fn get(&self, kind: KeyKind, keys: &[[u8; 32]]) -> Result<Vec<QuantRow>, StoreError> {
        unimplemented!("{kind:?} {}", keys.len())
    }

    /// STORE_ID (a repo store's [`crate::CodeStore::holder_id`]) is a holder, live, if it is not one yet: every store
    /// on disk is, from the hub's start (MP-21).
    pub async fn register(&self, store_id: &str) -> Result<(), StoreError> {
        unimplemented!("{store_id}")
    }

    /// STORE_ID, a checkout at ROOT, now holds ADDED and no longer REMOVED of KIND: its live key set's diff since its
    /// last report, sent on every refresh. It is live again from NOW (milliseconds). The keys of both lists are marked
    /// used, so a key a holder dropped is the last of the unheld to go.
    pub async fn hold(
        &self,
        store_id: &str,
        root: &Path,
        kind: KeyKind,
        added: &[[u8; 32]],
        removed: &[[u8; 32]],
        now: i64,
    ) -> Result<(), StoreError> {
        unimplemented!(
            "{store_id} {} {kind:?} {} {} {now}",
            root.display(),
            added.len(),
            removed.len()
        )
    }

    /// Holders whose checkout is gone (no folder at their root) and that have not refreshed for IDLE by NOW
    /// (milliseconds) stop protecting their keys. How many.
    pub async fn release_gone(&self, now: i64, idle: Duration) -> Result<u32, StoreError> {
        unimplemented!("{now} {idle:?}")
    }

    /// Whether a live holder holds each of KEYS.
    pub async fn referenced(
        &self,
        kind: KeyKind,
        keys: &[[u8; 32]],
    ) -> Result<Vec<bool>, StoreError> {
        unimplemented!("{kind:?} {}", keys.len())
    }

    /// The bytes (key and stored vector) of the keys live holders hold.
    pub async fn live_bytes(&self) -> Result<u64, StoreError> {
        unimplemented!()
    }

    /// Every key a live holder holds is kept; of the rest, the most recently used up to CAP_BYTES. How many went.
    pub async fn collect(&self, cap_bytes: u64) -> Result<u32, StoreError> {
        unimplemented!("{cap_bytes}")
    }

    /// Stop the cache's thread and close it (and its writer lock). Blocking: not for an async worker.
    pub fn shutdown(self) {}
}

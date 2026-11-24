//! Vector packs in the hub (Hrafn redesign §9; the file format is `hrafn::vector_pack`): the vectors of a repo's keys
//! written to a file ([`export`]), and a file's vectors merged into the machine's caches ([`import`]).
//!
//! - **Export** takes the keys a tree (or every tree) of one repo store references and the vectors the caches have for
//!   them, from the fingerprint that covers most of them. It writes keys and vectors only.
//! - **Import** runs in the hub, the only writer of the caches. It refuses a fingerprint no model source of this machine
//!   can make query vectors for (unless `keep_all`), and keeps **only the keys a repo store here references** (proof of
//!   possession, after Cursor §15 [P1]): the open projects' stores report what they hold, and every other store file under
//!   `<state>/code/` is opened for the purpose (MP-21), so a closed repo still counts. A pack therefore cannot add vectors
//!   for code the importer does not have. With `keep_all` the whole pack is kept, for a repo opened later.

use super::caches::Caches;
use hrafn::vector_pack::{PACK_FORMAT, PackHeader, PackReader, read_pack, write_pack};
use hrafn::{CodeStore, ExportScope, KeyKind, QuantRow, StoreError};
use hrafn_embed::fingerprint::{Fingerprint, FingerprintRecord, Identity};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// What the answer to an export says, and the CLI prints before the path (spec §3: a vector pack is source-equivalent).
pub const WARNING: &str = "Vectors leak content: inversion attacks recover most short inputs (Vec2Text 92% exact on 32-token inputs; defences unreliable). A vector pack is treated as source-equivalent: this file can recreate the code's text. Share it only where you would share the code.";

/// Keys a batch of an import reads from the pack and writes to the cache at once.
const BATCH: usize = 1000;

#[derive(Debug)]
pub enum PackError {
    /// The request cannot be served (and the sentence says why): the user's to read.
    Refused(String),
    Store(StoreError),
}

impl std::fmt::Display for PackError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PackError::Refused(m) => f.write_str(m),
            PackError::Store(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for PackError {}

impl From<StoreError> for PackError {
    fn from(e: StoreError) -> Self {
        PackError::Store(e)
    }
}

fn refused(m: impl Into<String>) -> PackError {
    PackError::Refused(m.into())
}

/// A blocking call's result, a task that did not end being an error.
fn joined<T>(r: villa::Result<T>) -> Result<T, PackError> {
    r.map_err(|e| refused(format!("a pack task ended: {e}")))
}

/// What an export wrote.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Exported {
    pub path: PathBuf,
    /// The file's sha256, hex.
    pub sha256: String,
    /// The vectors in it (chunks and paths).
    pub keys: u64,
    /// The fingerprint they are of (64 hex characters) and its model.
    pub fingerprint: String,
    pub label: String,
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|b| format!("{b:02x}")).collect()
}

/// The vectors of STORE's keys under SCOPE written to OUT, of the fingerprint among the caches on disk that has the most
/// of them. CREATED_AT (seconds) goes in the header, with REPO's URL and commit when known.
pub async fn export(
    caches: &Caches,
    store: &CodeStore,
    scope: ExportScope,
    out: &Path,
    created_at: i64,
    repo: (Option<String>, Option<String>),
) -> Result<Exported, PackError> {
    let keys = hrafn::export_keys(store, scope).await?;
    let mut best: Option<(Identity, Vec<(KeyKind, QuantRow)>)> = None;
    for id in caches.stored() {
        let cache = caches.get(&id).await?;
        let mut rows = Vec::new();
        for kind in [KeyKind::Chunk, KeyKind::Path] {
            let ks: Vec<[u8; 32]> = keys
                .iter()
                .filter(|(k, _)| *k == kind)
                .map(|(_, k)| *k)
                .collect();
            rows.extend(cache.get(kind, &ks).await?.into_iter().map(|r| (kind, r)));
        }
        if best.as_ref().is_none_or(|(_, b)| rows.len() > b.len()) {
            best = Some((id, rows));
        }
    }
    let Some((id, rows)) = best.filter(|(_, r)| !r.is_empty()) else {
        return Err(refused(
            "no vectors to export for this tree yet: let the index finish embedding, then try again",
        ));
    };
    let header = PackHeader {
        format: PACK_FORMAT,
        record: id.record.to_json(),
        created_at,
        tool_version: env!("CARGO_PKG_VERSION").to_string(),
        repo_url: repo.0,
        commit: repo.1,
    };
    let n = rows.len() as u64;
    let path = out.to_path_buf();
    let sha = joined(
        crate::clock::blocking(move || write_pack(&path, &header, rows.into_iter())).await,
    )??;
    Ok(Exported {
        path: out.to_path_buf(),
        sha256: hex(&sha),
        keys: n,
        fingerprint: id.fp.hex(),
        label: id.label,
    })
}

/// What an import did, in keys of the pack: chunk and path vectors count alike.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Imported {
    pub fingerprint: String,
    pub label: String,
    pub keys_in_pack: u64,
    /// Written to the cache now.
    pub kept: u64,
    /// No repo store here references them (and `keep_all` was not given).
    pub skipped_unreferenced: u64,
    /// Referenced, and the cache had them.
    pub already_had: u64,
}

impl Imported {
    /// One line for the CLI.
    pub fn summary(&self) -> String {
        summary(
            self.keys_in_pack,
            self.kept,
            self.already_had,
            self.skipped_unreferenced,
        )
    }
}

/// An import's one line: N keys in the pack, KEPT written now, ALREADY here, SKIPPED referenced by no repo.
pub fn summary(n: u64, kept: u64, already: u64, skipped: u64) -> String {
    if n == 0 {
        "the pack holds no keys".to_string()
    } else if kept == 0 && already == 0 {
        format!("0 of {n} keys kept: no repo here references them")
    } else {
        format!(
            "{kept} of {n} keys kept ({already} already here, {skipped} referenced by no repo here)"
        )
    }
}

/// An open repo store of the hub and its checkout.
pub struct HeldStore<'a> {
    pub store: &'a CodeStore,
    pub root: &'a Path,
}

/// Whether a vector row of the pack is the size RECORD's dims say: the sign bits, then one int8 per dimension.
fn row_fits(r: &QuantRow, dims: usize) -> bool {
    r.bits == 8 && r.vec.len() == dims.div_ceil(8) + dims && r.scale.is_finite()
}

/// FILE's vectors merged into the caches, only for the keys a repo store here references unless KEEP_ALL. OPEN are the
/// hub's open stores (with their checkouts); the other stores under `<state>/code/` are opened here. KNOWN are the
/// fingerprints this machine's sources and engines can make query vectors for; a pack of another one is refused unless
/// KEEP_ALL. NOW_MS stamps the holders' refresh.
pub async fn import(
    caches: &Caches,
    file: &Path,
    open: &[HeldStore<'_>],
    known: &[Fingerprint],
    keep_all: bool,
    now_ms: i64,
) -> Result<Imported, PackError> {
    let f = file.to_path_buf();
    let (header, reader) = joined(crate::clock::blocking(move || read_pack(&f)).await)??;
    let reader: Arc<PackReader> = Arc::new(reader);
    let record = FingerprintRecord::from_json(&header.record)
        .map_err(|e| refused(format!("the pack's fingerprint record: {e}")))?;
    let label = record.model_id.clone();
    let id = Identity::new(record, label);
    if !keep_all && !known.contains(&id.fp) {
        return Err(refused(format!(
            "no source or engine of this machine makes query vectors for fingerprint {} ({}): its vectors would never \
             be searched; import with --keep-all to keep them anyway",
            id.fp.hex16(),
            id.label
        )));
    }
    let dims = id.record.dims as usize;
    let by_kind = {
        let r = reader.clone();
        joined(
            crate::clock::blocking(move || -> Result<_, StoreError> {
                Ok([
                    (KeyKind::Chunk, r.keys(KeyKind::Chunk)?),
                    (KeyKind::Path, r.keys(KeyKind::Path)?),
                ])
            })
            .await,
        )??
    };
    let keys_in_pack = by_kind.iter().map(|(_, k)| k.len() as u64).sum();
    let cache = caches.get(&id).await?;
    if !keep_all {
        hold_all(caches, &cache, open, now_ms).await?;
    }
    let (mut kept, mut already_had) = (0u64, 0u64);
    for (kind, keys) in &by_kind {
        for batch in keys.chunks(BATCH) {
            let wanted = if keep_all {
                vec![true; batch.len()]
            } else {
                cache.referenced(*kind, batch).await?
            };
            let have = cache.has(*kind, batch).await?;
            let mut put = Vec::new();
            for ((k, wanted), have) in batch.iter().zip(wanted).zip(have) {
                match (wanted, have) {
                    (true, true) => already_had += 1,
                    (true, false) => put.push(*k),
                    (false, _) => {}
                }
            }
            if put.is_empty() {
                continue;
            }
            let (r, kind2) = (reader.clone(), *kind);
            let rows = joined(crate::clock::blocking(move || r.rows(kind2, &put)).await)??;
            if let Some(bad) = rows.iter().find(|r| !row_fits(r, dims)) {
                return Err(refused(format!(
                    "the pack's vector for key {} is not {dims} dimensions of int8: not written",
                    hex(&bad.key[..4])
                )));
            }
            cache.put_quantized(*kind, &rows).await?;
            kept += rows.len() as u64;
        }
    }
    Ok(Imported {
        fingerprint: id.fp.hex(),
        label: id.label,
        keys_in_pack,
        kept,
        skipped_unreferenced: keys_in_pack - kept - already_had,
        already_had,
    })
}

/// Every repo store on this machine reports its live key set to CACHE: the open ones under their checkouts, the others
/// (files under `<state>/code/`) opened for it and closed again, held with no checkout (as the first open of a cache
/// registers them: never released as gone).
async fn hold_all(
    caches: &Caches,
    cache: &hrafn::VectorCache,
    open: &[HeldStore<'_>],
    now_ms: i64,
) -> Result<(), PackError> {
    for h in open {
        hrafn::hold(h.store, cache, h.root, now_ms).await?;
    }
    let open_ids: Vec<String> = open.iter().map(|h| h.store.holder_id()).collect();
    for id in caches.stores() {
        if open_ids.contains(&id) {
            continue;
        }
        let path = caches.state().join("code").join(format!("{id}.db"));
        let store = joined(crate::clock::blocking(move || CodeStore::open(&path)).await)??;
        let held = hrafn::hold(&store, cache, Path::new(""), now_ms).await;
        joined(crate::clock::blocking(move || store.shutdown()).await)?;
        held?;
    }
    Ok(())
}

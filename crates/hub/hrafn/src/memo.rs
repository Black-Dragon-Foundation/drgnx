//! What every query reads that only a change of the store moves: the lag counts, the vectors' sign bits and the
//! reference graphs (`graph.rs`). Kept for
//! one store generation (the store thread's own changes and other connections' commits), so a query between two index
//! writes reads neither again. At 100,000 chunks the lag probes were 38 ms and the scan of the vectors 28 ms of each
//! query.

use crate::tree::View;
use rusqlite::Connection;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

/// The counts of a view's lag that need a pass over the store.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct Counts {
    pub chunks_total: u32,
    pub chunks_behind: u32,
    pub files_behind: u32,
    pub differing_files: Option<u32>,
}

/// A model's vectors of one size: each key, and its sign bits (`BYTES` a vector, in the keys' order). About 32 bytes
/// plus a bit a dimension per vector: 8 MB for 100,000 vectors of 384 dimensions.
pub(crate) struct Signs {
    pub model: String,
    pub dims: usize,
    pub bytes: usize,
    pub keys: Vec<[u8; 32]>,
    pub bits: Vec<u8>,
}

impl Signs {
    pub fn get(&self, i: usize) -> &[u8] {
        &self.bits[i * self.bytes..(i + 1) * self.bytes]
    }
}

#[derive(Default)]
pub(crate) struct Memo {
    generation: Option<(u64, i64)>,
    /// The attached vector cache's file and its `data_version` (`store::ensure_vc`).
    vectors: Option<Option<(String, i64)>>,
    pub lag: HashMap<(Option<String>, View), Counts>,
    pub signs: Option<Signs>,
    pub graphs: crate::graph::Graphs,
}

impl Memo {
    /// The memo as of the store's state now: emptied when anything was written since it was filled. What reads the
    /// vectors (the lag, the sign bits) goes too when another cache is attached or the cache's writer committed; the
    /// graphs, which read no vector, stay then.
    pub fn at(&mut self, c: &Connection) -> rusqlite::Result<&mut Memo> {
        let now = Some(generation(c)?);
        let vectors = Some(attached(c)?);
        if self.generation != now {
            self.lag.clear();
            self.signs = None;
            self.graphs.clear();
            self.generation = now;
        } else if self.vectors != vectors {
            self.lag.clear();
            self.signs = None;
        }
        self.vectors = vectors;
        Ok(self)
    }
}

/// The store's generation: the changes this connection made (every write runs on the store thread's one connection) and
/// SQLite's `data_version`, which moves when another connection commits.
fn generation(c: &Connection) -> rusqlite::Result<(u64, i64)> {
    Ok((
        c.total_changes(),
        c.query_row("pragma data_version", [], |r| r.get(0))?,
    ))
}

/// The vector cache attached as `vc` (its file) and its `data_version`, which moves with every commit of its writer
/// (another process's connection); none when nothing is attached.
fn attached(c: &Connection) -> rusqlite::Result<Option<(String, i64)>> {
    let mut st = c.prepare("pragma database_list")?;
    let file: Option<String> = st
        .query_map([], |r| Ok((r.get::<_, String>(1)?, r.get::<_, String>(2)?)))?
        .filter_map(Result::ok)
        .find(|(name, _)| name == "vc")
        .map(|(_, f)| f);
    match file {
        None => Ok(None),
        Some(f) => Ok(Some((
            f,
            c.query_row("pragma vc.data_version", [], |r| r.get(0))?,
        ))),
    }
}

pub(crate) type Shared = Arc<Mutex<Memo>>;

pub(crate) fn lock(m: &Shared) -> MutexGuard<'_, Memo> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

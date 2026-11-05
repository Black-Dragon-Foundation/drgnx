//! The index: tier 1 (chunks, FTS rows and symbols, rebuilt for the files whose blob changed) and the store side of
//! tier 2 (which content keys a model still lacks, their vectors, and the keys kept for a branch switch back).
//!
//! Vectors are keyed by content ([`crate::vec_key`]), so a file that comes back to an earlier content finds its
//! vectors still there. Each vector row's `last_used` is a logical clock (one more than the store's highest), moved
//! on write and whenever tier 1 writes a chunk that refers to the key; unreferenced keys are kept up to twice the live
//! set, the least recently referenced going first.

use crate::chunk::{BUDGET, CHUNKER_VERSION, chunk_file};
use crate::files::Listed;
use crate::store::{
    ChunkIn, CodeStore, FileRow, StoreError, SymbolIn, vec_key, write_chunks, write_file_row,
};
use rusqlite::{Connection, params};
use std::collections::{HashMap, HashSet};
use std::io;
use std::time::{SystemTime, UNIX_EPOCH};

/// Files rebuilt in one transaction.
const FILE_BATCH: usize = 64;

const META_CHUNKER: &str = "chunker_version";
/// The commit the index was last built from (the hub writes it).
pub const META_BUILT_FROM: &str = "built_from";
/// Files known changed on disk and not yet rebuilt (the hub writes it).
pub const META_DIRTY: &str = "dirty_files";

/// What one tier-1 pass did. `keys_missing` counts, over the models given, the content keys each still lacks.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Refresh {
    pub files_changed: u32,
    pub chunks_written: u32,
    pub keys_missing: u32,
}

/// How far behind the index is.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Lag {
    pub model: Option<String>,
    /// The chunks that are embedded at all (the live set a model's coverage is judged against).
    pub chunks_total: u32,
    pub chunks_behind: u32,
    pub files_behind: u32,
    pub dirty_files: u32,
    pub built_from: String,
}

/// Each indexed file's blob.
pub(crate) fn known_blobs(c: &Connection) -> urdr::Result<HashMap<String, String>> {
    let mut q = c.prepare("select path, blob from file")?;
    let rows = q
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<HashMap<String, String>, _>>()?;
    Ok(rows)
}

fn next_used(c: &Connection) -> urdr::Result<i64> {
    Ok(
        c.query_row("select coalesce(max(last_used), 0) + 1 from vec", [], |r| {
            r.get(0)
        })?,
    )
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn count(c: &Connection, sql: &str, model: &str) -> urdr::Result<u32> {
    let n: i64 = c.query_row(sql, [model], |r| r.get(0))?;
    Ok(u32::try_from(n).unwrap_or(u32::MAX))
}

const MISSING_KEYS: &str =
    "select count(distinct c.key) from chunk c where c.embed = 1 and not exists
     (select 1 from vec v where v.model = ?1 and v.key = c.key)";

/// One file's rows, chunked off the store thread.
struct Built {
    row: FileRow,
    chunks: Vec<ChunkIn>,
    symbols: Vec<SymbolIn>,
}

fn build(l: &Listed, bytes: &[u8]) -> Built {
    let text = String::from_utf8_lossy(bytes);
    let (chunks, symbols) = chunk_file(&l.path, l.lang, l.generated, &text, BUDGET);
    Built {
        row: FileRow {
            path: l.path.clone(),
            blob: l.blob.clone(),
            class: l.class.as_str().into(),
            lang: l.lang.as_str().into(),
            generated: l.generated,
            size: l.size,
            indexed_at: now_secs(),
        },
        chunks: chunks
            .into_iter()
            .map(|c| ChunkIn {
                start: c.start,
                end: c.end,
                line_start: c.line_start,
                line_end: c.line_end,
                symbol: c.symbol,
                key: vec_key(CHUNKER_VERSION, &c.embed_text),
                embed: c.embed,
                embed_text: c.embed_text,
                symbols: c.fts.symbols,
                doc: c.fts.doc,
                body: c.fts.body,
            })
            .collect(),
        symbols: symbols
            .into_iter()
            .map(|s| SymbolIn {
                name: s.name,
                kind: s.kind,
                start: s.start,
                end: s.end,
                chunk: s.chunk as usize,
                definer: s.definer,
                doc1: s.doc1,
            })
            .collect(),
    }
}

/// Tier 1: rows rebuilt only for the files of `listed` whose blob changed (all of them after a chunker change), and
/// dropped for the files no longer listed; one transaction per batch of files. `read` gives a listed file's bytes
/// (the hub's reads go through `eitri`); a file that cannot be read any more is dropped like a gone one. `models` are
/// the `(model, dims)` that tier 2 fills, for `keys_missing`.
pub async fn refresh(
    store: &CodeStore,
    listed: &[Listed],
    read: &(dyn Fn(&str) -> io::Result<Vec<u8>> + Sync),
    models: &[(&str, usize)],
) -> Result<Refresh, StoreError> {
    let (known, chunker) = store
        .handle()
        .read(|c| Ok((known_blobs(c)?, urdr::meta(c, META_CHUNKER)?)))
        .await?;
    let rebuild = chunker.as_deref() != Some(CHUNKER_VERSION.to_string().as_str());
    let names: HashSet<&str> = listed.iter().map(|l| l.path.as_str()).collect();
    let mut gone: Vec<String> = known
        .keys()
        .filter(|p| !names.contains(p.as_str()))
        .cloned()
        .collect();
    let changed: Vec<&Listed> = listed
        .iter()
        .filter(|l| rebuild || known.get(&l.path) != Some(&l.blob))
        .collect();
    let mut out = Refresh::default();
    for batch in changed.chunks(FILE_BATCH) {
        let mut built = Vec::with_capacity(batch.len());
        for l in batch {
            match read(&l.path) {
                Ok(bytes) => built.push(build(l, &bytes)),
                Err(_) if known.contains_key(&l.path) => gone.push(l.path.clone()),
                Err(_) => {}
            }
        }
        out.files_changed += built.len() as u32;
        out.chunks_written += built.iter().map(|b| b.chunks.len() as u32).sum::<u32>();
        store
            .handle()
            .write(move |c| {
                let used = next_used(c)?;
                for b in &built {
                    write_file_row(c, &b.row)?;
                    write_chunks(c, &b.row.path, &b.chunks, &b.symbols)?;
                    for ch in &b.chunks {
                        c.execute(
                            "update vec set last_used = ?1 where key = ?2",
                            params![used, ch.key.as_slice()],
                        )?;
                    }
                }
                Ok(())
            })
            .await?;
    }
    if !gone.is_empty() {
        out.files_changed += gone.len() as u32;
        store
            .handle()
            .write(move |c| {
                for p in &gone {
                    c.execute("delete from chunk where path = ?1", [p])?;
                    c.execute("delete from file where path = ?1", [p])?;
                }
                Ok(())
            })
            .await?;
    }
    if rebuild {
        store
            .meta_set(META_CHUNKER, &CHUNKER_VERSION.to_string())
            .await?;
    }
    let models: Vec<String> = models.iter().map(|(m, _)| m.to_string()).collect();
    out.keys_missing = store
        .handle()
        .read(move |c| {
            let mut n = 0u32;
            for m in &models {
                n = n.saturating_add(count(c, MISSING_KEYS, m)?);
            }
            Ok(n)
        })
        .await?;
    Ok(out)
}

/// Up to `limit` content keys MODEL lacks, with the text to embed, in chunk order.
pub async fn missing(
    store: &CodeStore,
    model: &str,
    limit: u32,
) -> Result<Vec<([u8; 32], String)>, StoreError> {
    let model = model.to_string();
    Ok(store
        .handle()
        .read(move |c| {
            let mut q = c.prepare(
                "select c.key, c.embed_text from chunk c
                 where c.id in (select min(id) from chunk where embed = 1 group by key)
                   and not exists (select 1 from vec v where v.model = ?1 and v.key = c.key)
                 order by c.id limit ?2",
            )?;
            let rows = q
                .query_map(params![model, limit], |r| {
                    let key: Vec<u8> = r.get(0)?;
                    Ok((key, r.get::<_, String>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows
                .into_iter()
                .filter_map(|(k, t)| Some((<[u8; 32]>::try_from(k.as_slice()).ok()?, t)))
                .collect())
        })
        .await?)
}

/// MODEL's vectors for content keys. Each is stored quantized (`urdr::graph::search::vec::quantize`): `vec` holds the
/// sign bits (`dims / 8` bytes, rounded up) and then the int8 values, `scale` their scale, and `bits` is 8.
pub async fn put_vectors(
    store: &CodeStore,
    model: &str,
    rows: &[([u8; 32], Vec<f32>)],
) -> Result<(), StoreError> {
    let model = model.to_string();
    let rows: Vec<_> = rows
        .iter()
        .map(|(key, v)| {
            let (bits, ints, scale) = urdr::graph::search::vec::quantize(v);
            let mut blob = bits;
            blob.extend(ints.iter().map(|&i| i as u8));
            (*key, v.len() as u32, blob, scale)
        })
        .collect();
    Ok(store
        .handle()
        .write(move |c| {
            let used = next_used(c)?;
            for (key, dims, blob, scale) in &rows {
                c.execute(
                    "insert or replace into vec(model, dims, key, bits, vec, scale, last_used)
                     values (?1, ?2, ?3, 8, ?4, ?5, ?6)",
                    params![model, dims, key.as_slice(), blob, scale, used],
                )?;
            }
            Ok(())
        })
        .await?)
}

/// Drops MODEL's unreferenced keys beyond twice the live set, least recently referenced first. How many went.
pub async fn collect(store: &CodeStore, model: &str) -> Result<u32, StoreError> {
    let model = model.to_string();
    Ok(store
        .handle()
        .write(move |c| {
            let live: i64 = c.query_row(
                "select count(distinct key) from chunk where embed = 1",
                [],
                |r| r.get(0),
            )?;
            let n = c.execute(
                "delete from vec where model = ?1 and key in (
                   select v.key from vec v
                   where v.model = ?1 and not exists (select 1 from chunk c where c.key = v.key)
                   order by v.last_used desc limit -1 offset ?2)",
                params![model, live * 2],
            )?;
            Ok(u32::try_from(n).unwrap_or(u32::MAX))
        })
        .await?)
}

/// How far behind the index is for MODEL (none: no model fills tier 2, so nothing is behind on vectors).
pub async fn lag(store: &CodeStore, model: Option<&str>) -> Result<Lag, StoreError> {
    let model = model.map(str::to_string);
    Ok(store
        .handle()
        .read(move |c| {
            let (chunks_behind, files_behind) = match &model {
                None => (0, 0),
                Some(m) => {
                    let behind = "from chunk c where c.embed = 1 and not exists
                       (select 1 from vec v where v.model = ?1 and v.key = c.key)";
                    (
                        count(c, &format!("select count(*) {behind}"), m)?,
                        count(c, &format!("select count(distinct c.path) {behind}"), m)?,
                    )
                }
            };
            let total: i64 =
                c.query_row("select count(*) from chunk where embed = 1", [], |r| {
                    r.get(0)
                })?;
            Ok(Lag {
                chunks_total: u32::try_from(total).unwrap_or(u32::MAX),
                chunks_behind,
                files_behind,
                dirty_files: urdr::meta(c, META_DIRTY)?
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0),
                built_from: urdr::meta(c, META_BUILT_FROM)?.unwrap_or_default(),
                model,
            })
        })
        .await?)
}
